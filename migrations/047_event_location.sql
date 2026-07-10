-- 047_event_location.sql
--
-- Events can carry a location: a bar (the group gets CHECKED IN there
-- automatically when the event goes live) or a free-form spot/address
-- (set as the group's pre-game location). The payload column holds a
-- client-encoded Venue or LooseSpot JSON — the lifecycle job copies it
-- verbatim onto the auto-created session's live_venue / live_loose_spot,
-- and the EXISTING group-broadcast observers on every member's device do
-- the actual check-in / pre-game adoption. No new client sync machinery.

alter table public.events
  add column if not exists location_kind text
    check (location_kind in ('venue', 'spot')),
  add column if not exists location_name text,
  add column if not exists location jsonb;

create or replace function public.set_event_location(
  p_event uuid, p_kind text, p_name text, p_payload jsonb
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind is not null and p_kind not in ('venue', 'spot') then
    raise exception 'invalid location kind';
  end if;
  update events
     set location_kind = p_kind,
         location_name = case when p_kind is null then null else p_name end,
         location      = case when p_kind is null then null else p_payload end
   where id = p_event and host_id = auth.uid();
end; $$;

revoke execute on function public.set_event_location(uuid, text, text, jsonb) from public;
revoke execute on function public.set_event_location(uuid, text, text, jsonb) from anon;
grant execute on function public.set_event_location(uuid, text, text, jsonb) to authenticated;

-- Lifecycle: unchanged except the new session inherits the event's
-- location (venue → live_venue = auto check-in; spot → live_loose_spot =
-- pre-game) before members are notified.
create or replace function public.run_event_live_lifecycle()
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  ev record;
  v_session uuid;
  v_code text;
  v_event_end timestamptz;
  v_last_activity timestamptz;
  v_session_active boolean;
begin
  for ev in
    select * from events e
    where e.auto_live
      and e.live_session_id is null
      and e.starts_at <= now()
      and e.starts_at > now() - interval '12 hours'
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

  for ev in
    select * from events e
    where e.live_session_id is not null
      and e.live_ended_at is null
  loop
    select s.active_live into v_session_active
      from sessions s where s.id = ev.live_session_id;

    if v_session_active is distinct from true then
      update events set live_ended_at = now() where id = ev.id;
      continue;
    end if;

    v_event_end := ev.starts_at
      + make_interval(days => greatest(ev.nights, 1) - 1)
      + (ev.duration_hours * interval '1 hour');

    select max(d.created_at) into v_last_activity
      from session_drinks d
     where d.session_id = ev.live_session_id;
    v_last_activity := greatest(
      coalesce(v_last_activity, ev.live_started_at),
      ev.live_started_at
    );

    if now() >= v_event_end and now() >= v_last_activity + interval '6 hours' then
      update sessions set active_live = false where id = ev.live_session_id;
      update events set live_ended_at = now() where id = ev.id;
    end if;
  end loop;
exception when others then
  return;
end $$;
