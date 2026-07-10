-- 044_event_live_link.sql
--
-- Events grow up:
--  * cover_url + 'event-covers' storage bucket (host-managed photo)
--  * auto_live: the host can arm an event to START A LIVE GROUP SESH
--    automatically at starts_at. Every going member is inserted into the
--    session (in_live), so the existing client resume path pulls them in
--    the moment they open the app. The sesh is linked to the event and
--    ends no earlier than the event's scheduled end; past that it stays
--    alive as long as drinks keep being logged, and closes once 6 hours
--    pass without a new drink on any account.
--  * pg_cron runs the lifecycle every 5 minutes (same pattern as 034).

alter table public.events
  add column if not exists cover_url text,
  add column if not exists auto_live boolean not null default false,
  add column if not exists live_session_id uuid references public.sessions(id) on delete set null,
  add column if not exists live_started_at timestamptz,
  add column if not exists live_ended_at timestamptz;

-- ─── cover photos ──────────────────────────────────────────────────────

insert into storage.buckets (id, name, public)
values ('event-covers', 'event-covers', true)
on conflict (id) do nothing;

-- Path: {event_id}/cover.jpg — host only. Upsert needs BOTH insert and
-- update policies on storage.objects.
drop policy if exists event_covers_insert on storage.objects;
create policy event_covers_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'event-covers'
    and exists (
      select 1 from public.events e
      where e.id::text = (storage.foldername(name))[1]
        and e.host_id = auth.uid()
    )
  );

drop policy if exists event_covers_update on storage.objects;
create policy event_covers_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'event-covers'
    and exists (
      select 1 from public.events e
      where e.id::text = (storage.foldername(name))[1]
        and e.host_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'event-covers'
    and exists (
      select 1 from public.events e
      where e.id::text = (storage.foldername(name))[1]
        and e.host_id = auth.uid()
    )
  );

drop policy if exists event_covers_delete on storage.objects;
create policy event_covers_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'event-covers'
    and exists (
      select 1 from public.events e
      where e.id::text = (storage.foldername(name))[1]
        and e.host_id = auth.uid()
    )
  );

create or replace function public.set_event_cover(p_event uuid, p_url text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events set cover_url = p_url
   where id = p_event and host_id = auth.uid();
end; $$;

create or replace function public.set_event_auto_live(p_event uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events set auto_live = coalesce(p_on, auto_live)
   where id = p_event and host_id = auth.uid();
end; $$;

-- create_event gains p_auto_live — replace the old 6-arg signature.
drop function if exists public.create_event(text, text, timestamptz, numeric, integer, numeric);
create or replace function public.create_event(
  p_title text, p_kind text, p_starts_at timestamptz,
  p_duration_hours numeric, p_nights integer, p_target_bac numeric,
  p_auto_live boolean default false
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  insert into events (host_id, title, kind, starts_at, duration_hours, nights, target_bac, auto_live)
  values (auth.uid(), p_title, p_kind, p_starts_at, p_duration_hours,
          coalesce(p_nights, 1), coalesce(p_target_bac, 0.08), coalesce(p_auto_live, false))
  returning id into v_id;

  insert into event_members (event_id, profile_id, status, responded_at)
  values (v_id, auth.uid(), 'going', now());

  return v_id;
end; $$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'set_event_cover(uuid,text)',
    'set_event_auto_live(uuid,boolean)',
    'create_event(text,text,timestamptz,numeric,integer,numeric,boolean)'
  ] loop
    execute format('revoke execute on function public.%s from public', fn);
    execute format('revoke execute on function public.%s from anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ─── auto start/end lifecycle ──────────────────────────────────────────

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
  -- START: armed events whose time has come (skip anything >12h stale so
  -- an old forgotten event can't spring to life on cron recovery).
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

  -- END: linked sessions. The sesh survives until BOTH the event's
  -- scheduled end has passed AND no drink has been logged for 6 hours
  -- (each drink extends the afterparty window).
  for ev in
    select * from events e
    where e.live_session_id is not null
      and e.live_ended_at is null
  loop
    select s.active_live into v_session_active
      from sessions s where s.id = ev.live_session_id;

    if v_session_active is distinct from true then
      -- Ended by hand (host END) or vanished — just stamp the link.
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
  -- Never let one bad row wedge the cron job.
  return;
end $$;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'event-live-lifecycle') then
    perform cron.schedule('event-live-lifecycle', '*/5 * * * *',
                          'select public.run_event_live_lifecycle()');
  end if;
end $$;
