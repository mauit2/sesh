-- 134: N+1 queries folded into joins.
--
-- friends_live_pulse is polled by every phone every three minutes and on
-- every visit to the live tab. It looped over the caller's friends and ran
-- up to five queries per friend (presence, session, head count, own
-- drinks, other members with nested per-member drinks). One set-based
-- statement now, with the per-friend pieces as LEFT JOIN LATERAL so a
-- friend who is not live costs one join row and nothing else. The output
-- is byte-for-byte the same shape, ordered by name.
--
-- run_event_live_lifecycle read the session and the last drink per event;
-- both ride the cursor now. notify_business_followers updated the follow
-- row once per follower; one UPDATE for the batch.

create or replace function private.friends_live_pulse_for(p_me uuid)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(e.entry order by e.name), '[]'::jsonb)
  from (
    select f.name,
      jsonb_build_object('id', f.id, 'name', f.name, 'username', f.username,
                         'avatar_url', f.avatar_url, 'live', false)
      || case when pres.user_id is null then '{}'::jsonb else jsonb_build_object(
           'live', true,
           'bac', round(widmark_bac(ev.events, f.weight_kg, f.sex, now())::numeric, 3),
           'drinks', ev.cnt,
           'venue', coalesce(sess.live_venue->>'name', pres.venue_name),
           'venue_lat', coalesce((sess.live_venue->>'lat')::float8, pres.venue_lat),
           'venue_lon', coalesce((sess.live_venue->>'lon')::float8, pres.venue_lon),
           'started_epoch', extract(epoch from pres.started_at),
           'members', coalesce(mems.arr, '[]'::jsonb)) end as entry
    from friendships fr
    join profiles f
      on f.id = case when fr.requester_id = p_me then fr.addressee_id else fr.requester_id end
    -- A friend's presence row, if it is a live night (started, seen in 16 h).
    left join live_presence pres
      on pres.user_id = f.id
     and pres.started_at is not null
     and pres.updated_at > now() - interval '16 hours'
    -- Their live group, if the presence points at one that is still running.
    left join sessions sess
      on sess.id = pres.session_id and sess.active_live
    -- Headcount a shared round divides by: live members + guests. Mirrors
    -- the client's sharedHeadCount exactly.
    left join lateral (
      select greatest(count(*) + coalesce(jsonb_array_length(sess.ghosts), 0), 1) as n
        from session_members sm
       where sm.session_id = sess.id and sm.in_live
    ) h on sess.id is not null
    -- The friend's own ledger: in a group, personal drinks at full grams and
    -- shared rounds at their per-head share; solo, the presence row's drinks.
    left join lateral (
      select x.events, (select count(*) from jsonb_array_elements(x.events)) as cnt
        from (select case when sess.id is null then coalesce(pres.drinks, '[]'::jsonb)
                     else coalesce((
                       select jsonb_agg(jsonb_build_object('t', d.created_at,
                                'g', (d.volume_ml * d.abv * 0.789) / case when d.shared then h.n else 1 end)
                              order by d.created_at)
                         from session_drinks d
                        where d.session_id = sess.id and d.live
                          and (d.profile_id = f.id or d.shared)), '[]'::jsonb)
                     end as events) x
    ) ev on pres.user_id is not null
    -- Everyone else in the group, same per-head math.
    left join lateral (
      select jsonb_agg(jsonb_build_object(
               'id', mp.id, 'name', mp.name, 'avatar_url', mp.avatar_url,
               'drinks', (select count(*) from session_drinks d2
                           where d2.session_id = sess.id and d2.live
                             and (d2.profile_id = mp.id or d2.shared)),
               'bac', round(widmark_bac(
                        (select coalesce(jsonb_agg(jsonb_build_object('t', d3.created_at,
                                  'g', (d3.volume_ml * d3.abv * 0.789) / case when d3.shared then h.n else 1 end)
                                order by d3.created_at), '[]'::jsonb)
                           from session_drinks d3
                          where d3.session_id = sess.id and d3.live
                            and (d3.profile_id = mp.id or d3.shared)),
                        mp.weight_kg, mp.sex, now())::numeric, 3))) as arr
        from session_members sm
        join profiles mp on mp.id = sm.profile_id
       where sm.session_id = sess.id and sm.in_live and sm.profile_id <> f.id
    ) mems on sess.id is not null
    where fr.status = 'accepted'
      and (fr.requester_id = p_me or fr.addressee_id = p_me)
  ) e;
$$;

create or replace function public.friends_live_pulse()
returns jsonb
language sql stable security definer
set search_path = public, private
as $$
  select case when auth.uid() is null then '[]'::jsonb
              else private.friends_live_pulse_for(auth.uid()) end;
$$;

create or replace function public.run_event_live_lifecycle()
returns void language plpgsql security definer set search_path = public, private as $$
declare
  ev record;
  v_session uuid;
  v_code text;
  v_event_end timestamptz;
  v_last_activity timestamptz;
begin
  for ev in
    select * from events e
    where e.auto_live
      and e.live_session_id is null
      and e.starts_at <= now()
      and e.starts_at > now() - interval '12 hours'
    for update skip locked
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    insert into sessions (host_id, join_code, active_plan, active_live)
    values (ev.host_id, v_code, false, true)
    returning id into v_session;

    if ev.location is not null and ev.location_kind = 'venue' then
      update sessions set live_venue = ev.location where id = v_session;
    elsif ev.location is not null and ev.location_kind = 'spot' then
      update sessions set live_loose_spot = ev.location where id = v_session;
    end if;

    insert into session_members (session_id, profile_id, in_plan, in_live)
    select v_session, m.profile_id, false, true
    from event_members m
    where m.event_id = ev.id and m.status = 'going';

    update events
       set live_session_id = v_session, live_started_at = now()
     where id = ev.id;

    perform private.notify_push(
      m.profile_id,
      '🔴 ' || ev.title || ' just went live',
      'Your group sesh is running — open sesh and start logging.',
      jsonb_build_object('type', 'event_live', 'event_id', ev.id)
    )
    from event_members m
    where m.event_id = ev.id and m.status = 'going';
  end loop;

  -- The session's state and its last drink ride the cursor: one statement
  -- for every running event instead of two reads per event.
  for ev in
    select e.*, s.active_live as session_active,
           (select max(d.created_at) from session_drinks d where d.session_id = e.live_session_id) as last_drink
      from events e
      left join sessions s on s.id = e.live_session_id
     where e.live_session_id is not null
       and e.live_ended_at is null
     for update of e skip locked
  loop
    if ev.session_active is distinct from true then
      update events set live_ended_at = now() where id = ev.id;
      continue;
    end if;

    v_event_end := ev.starts_at
      + make_interval(days => greatest(ev.nights, 1) - 1)
      + (ev.duration_hours * interval '1 hour');

    v_last_activity := greatest(coalesce(ev.last_drink, ev.live_started_at), ev.live_started_at);

    if now() >= v_event_end and now() >= v_last_activity + interval '6 hours' then
      update sessions set active_live = false where id = ev.live_session_id;
      update events set live_ended_at = now() where id = ev.id;
    end if;
  end loop;
exception when others then
  return;
end $$;

create or replace function private.notify_business_followers(p_business uuid, p_title text, p_body text, p_data jsonb)
returns integer language plpgsql security definer set search_path = public, private as $$
declare v_owner uuid; v_ids uuid[];
begin
  select owner_id into v_owner from businesses where id = p_business;
  select coalesce(array_agg(user_id), '{}'::uuid[]) into v_ids
    from business_follows
   where business_id = p_business and notify
     and user_id is distinct from v_owner
     and (last_notified_at is null or last_notified_at < now() - interval '2 hours');
  perform private.notify_push(u, p_title, p_body, p_data) from unnest(v_ids) as u;
  -- One UPDATE for the whole batch instead of one per follower.
  update business_follows set last_notified_at = now()
   where business_id = p_business and user_id = any(v_ids);
  return coalesce(array_length(v_ids, 1), 0);
end $$;
