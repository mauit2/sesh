-- 032_live_presence_pulse.sql
--
-- Friends "live pulse": lets friends see each other's night in real time —
-- live or not, drink count, current BAC, check-in venue, and (for group
-- seshes) who they're with + those people's BACs.
--
-- Solo sesh data lives only on the device (LiveSeshState/UserDefaults), so
-- the app publishes a tiny presence row while a night is running:
--   • solo  → started_at + venue + a compact drinks array [{t, g}]
--   • group → started_at + venue + session_id (drinks already live in
--             session_drinks; no duplication)
-- The row is deleted when the night ends.
--
-- Reads go through ONE SECURITY DEFINER RPC (friends_live_pulse) that
-- assembles everything server-side — including co-members' BACs — so
-- clients never see anyone's weight/sex; only the computed BAC leaves
-- the database.

create table if not exists live_presence (
  user_id    uuid primary key references profiles(id) on delete cascade,
  started_at timestamptz,
  venue_name text,
  session_id uuid references sessions(id) on delete set null,
  drinks     jsonb not null default '[]',   -- [{t: timestamptz, g: grams}]
  updated_at timestamptz not null default now()
);

alter table live_presence enable row level security;

-- Owner writes own row (upsert needs INSERT + UPDATE + DELETE).
drop policy if exists live_presence_self_insert on live_presence;
create policy live_presence_self_insert on live_presence
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists live_presence_self_update on live_presence;
create policy live_presence_self_update on live_presence
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists live_presence_self_delete on live_presence;
create policy live_presence_self_delete on live_presence
  for delete to authenticated using (user_id = auth.uid());
-- Direct reads: self only. Friends read via the RPC, which re-checks
-- friendship itself — keeps raw drinks arrays out of reach.
drop policy if exists live_presence_self_select on live_presence;
create policy live_presence_self_select on live_presence
  for select to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on live_presence to authenticated;

-- Chronological Widmark walk, mirroring the client's LiveSeshState.bac():
-- each drink adds grams/(weight*1000*r)*100 instantly; BAC decays at
-- 0.015/hour between events, clamped at 0.
create or replace function widmark_bac(
  p_events jsonb, p_weight_kg float8, p_sex text, p_at timestamptz
) returns float8
language plpgsql immutable as $$
declare
  r float8 := case when p_sex = 'male' then 0.68 else 0.55 end;
  denom float8 := coalesce(p_weight_kg, 0) * 1000 * r;
  bac float8 := 0;
  last_t timestamptz := null;
  e record;
begin
  if denom <= 0 then return 0; end if;
  for e in
    select (x->>'t')::timestamptz as t, (x->>'g')::float8 as g
    from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) x
    where (x->>'t')::timestamptz <= p_at
    order by 1
  loop
    if last_t is not null then
      bac := greatest(0, bac - 0.015 * extract(epoch from e.t - last_t) / 3600.0);
    end if;
    bac := bac + (e.g / denom) * 100;
    last_t := e.t;
  end loop;
  if last_t is not null then
    bac := greatest(0, bac - 0.015 * extract(epoch from p_at - last_t) / 3600.0);
  end if;
  return bac;
end $$;

-- One row per accepted friend; live ones carry bac/drinks/venue and, for
-- group seshes, the co-members with THEIR bac + drink counts.
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
      mems := '[]'::jsonb;
      ev := pres.drinks;

      if pres.session_id is not null then
        select * into sess from sessions s
        where s.id = pres.session_id and s.active_live;
        if found then
          venue := coalesce(sess.live_venue->>'name', venue);
          -- Friend's own group ledger: personal + shared drinks, same
          -- shape the client's liveTimeline uses.
          select coalesce(jsonb_agg(
                   jsonb_build_object('t', d.created_at, 'g', d.volume_ml * d.abv * 0.789)
                   order by d.created_at), '[]'::jsonb)
          into ev
          from session_drinks d
          where d.session_id = sess.id and d.live
            and (d.profile_id = f.id or d.shared);

          -- Everyone else in the group, with their BAC + drink count.
          select coalesce(jsonb_agg(jsonb_build_object(
                   'id', mp.id, 'name', mp.name, 'avatar_url', mp.avatar_url,
                   'drinks', (select count(*) from session_drinks d2
                              where d2.session_id = sess.id and d2.live
                                and (d2.profile_id = mp.id or d2.shared)),
                   'bac', round(widmark_bac(
                     (select coalesce(jsonb_agg(
                        jsonb_build_object('t', d3.created_at, 'g', d3.volume_ml * d3.abv * 0.789)
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
        'started_epoch', extract(epoch from pres.started_at),
        'members', mems
      );
    end if;

    result := result || jsonb_build_array(entry);
  end loop;

  return result;
end $$;

revoke execute on function friends_live_pulse() from public, anon;
grant execute on function friends_live_pulse() to authenticated;
revoke execute on function widmark_bac(jsonb, float8, text, timestamptz) from public, anon;

notify pgrst, 'reload schema';
