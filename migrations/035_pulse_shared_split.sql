-- 035_pulse_shared_split.sql
--
-- BAC accuracy fix: friends_live_pulse counted SHARED drinks at full
-- strength for every member, while the app divides a shared round by the
-- headcount (live members + manually-added guests). A 4-person group
-- sharing rounds therefore showed everyone with up to 4x the alcohol in
-- the pulse strip. This brings the RPC in line with the client's math:
-- shared grams / headcount, personal grams untouched.

create or replace function friends_live_pulse()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  result jsonb := '[]'::jsonb;
  f record;
  pres record;
  sess record;
  entry jsonb;
  mems jsonb;
  ev jsonb;
  cnt int;
  b float8;
  venue text;
  v_lat float8;
  v_lon float8;
  heads int;
begin
  if me is null then return '[]'::jsonb; end if;

  for f in
    select p.id, p.name, p.username, p.avatar_url, p.weight_kg, p.sex
    from friendships fr
    join profiles p
      on p.id = case when fr.requester_id = me then fr.addressee_id else fr.requester_id end
    where fr.status = 'accepted'
      and (fr.requester_id = me or fr.addressee_id = me)
  loop
    entry := jsonb_build_object(
      'id', f.id, 'name', f.name, 'username', f.username,
      'avatar_url', f.avatar_url, 'live', false
    );

    select * into pres from live_presence lp
    where lp.user_id = f.id
      and lp.started_at is not null
      and lp.updated_at > now() - interval '16 hours';

    if found then
      venue := pres.venue_name;
      v_lat := pres.venue_lat;
      v_lon := pres.venue_lon;
      mems := '[]'::jsonb;
      ev := pres.drinks;

      if pres.session_id is not null then
        select * into sess from sessions s
        where s.id = pres.session_id and s.active_live;
        if found then
          venue := coalesce(sess.live_venue->>'name', venue);
          v_lat := coalesce((sess.live_venue->>'lat')::float8, v_lat);
          v_lon := coalesce((sess.live_venue->>'lon')::float8, v_lon);

          -- Headcount a shared round divides by: live members + guests.
          -- Mirrors the client's sharedHeadCount exactly.
          select count(*) into heads from session_members sm0
          where sm0.session_id = sess.id and sm0.in_live;
          heads := greatest(heads + coalesce(jsonb_array_length(sess.ghosts), 0), 1);

          -- Friend's own group ledger: personal drinks at full grams,
          -- shared rounds at their per-head share.
          select coalesce(jsonb_agg(
                   jsonb_build_object('t', d.created_at,
                     'g', (d.volume_ml * d.abv * 0.789)
                          / case when d.shared then heads else 1 end)
                   order by d.created_at), '[]'::jsonb)
          into ev
          from session_drinks d
          where d.session_id = sess.id and d.live
            and (d.profile_id = f.id or d.shared);

          -- Everyone else in the group, same per-head math.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'id', mp.id, 'name', mp.name, 'avatar_url', mp.avatar_url,
                   'drinks', (select count(*) from session_drinks d2
                              where d2.session_id = sess.id and d2.live
                                and (d2.profile_id = mp.id or d2.shared)),
                   'bac', round(widmark_bac(
                     (select coalesce(jsonb_agg(
                        jsonb_build_object('t', d3.created_at,
                          'g', (d3.volume_ml * d3.abv * 0.789)
                               / case when d3.shared then heads else 1 end)
                        order by d3.created_at), '[]'::jsonb)
                      from session_drinks d3
                      where d3.session_id = sess.id and d3.live
                        and (d3.profile_id = mp.id or d3.shared)),
                     mp.weight_kg, mp.sex, now())::numeric, 3)
                 )), '[]'::jsonb)
          into mems
          from session_members sm
          join profiles mp on mp.id = sm.profile_id
          where sm.session_id = sess.id and sm.in_live
            and sm.profile_id <> f.id;
        end if;
      end if;

      select count(*) into cnt from jsonb_array_elements(coalesce(ev, '[]'::jsonb));
      b := widmark_bac(ev, f.weight_kg, f.sex, now());

      entry := entry || jsonb_build_object(
        'live', true,
        'bac', round(b::numeric, 3),
        'drinks', cnt,
        'venue', venue,
        'venue_lat', v_lat,
        'venue_lon', v_lon,
        'started_epoch', extract(epoch from pres.started_at),
        'members', mems
      );
    end if;

    result := result || jsonb_build_array(entry);
  end loop;

  return result;
end $$;

notify pgrst, 'reload schema';
