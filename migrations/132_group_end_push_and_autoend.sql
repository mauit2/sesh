-- 132: the end of a group night reaches every member.
--
-- Recaps are built on each member's phone the moment it notices the
-- session ended. Until now nothing told the other phones: a member whose
-- app was closed found out on their next launch, often the next day, by
-- which time the squad snaps had been purged (see cleanup-snaps). Two
-- server-side pieces:
--   1. A push to every undelivered member (session_members.in_live still
--      true) when a live session ends — host END or the auto-end below.
--      The app delivers the recap when the push is tapped instead of
--      waiting for the next launch.
--   2. Groups the host forgot to end stayed live for days, and the app
--      then released them without a recap. Any live session with no
--      drink, stop or snap for 8 hours is ended automatically. Event
--      sessions keep their own lifecycle (run_event_live_lifecycle).

create or replace function private.on_session_live_ended()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  m record;
  ender uuid := auth.uid();   -- null when the cron ends it
begin
  if old.active_live and not new.active_live then
    for m in
      select profile_id from session_members
       where session_id = new.id and in_live
         and (ender is null or profile_id <> ender)
    loop
      perform private.notify_push(
        m.profile_id,
        '🍻 The night is over',
        'Your recap is ready — open Sejdel to see it.',
        jsonb_build_object('type', 'session_ended', 'session_id', new.id)
      );
    end loop;
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists session_live_ended on public.sessions;
create trigger session_live_ended
  after update of active_live on public.sessions
  for each row execute function private.on_session_live_ended();

create or replace function private.run_group_autoend()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  update sessions s
     set active_live = false
   where s.active_live
     and not exists (select 1 from events e
                      where e.live_session_id = s.id and e.live_ended_at is null)
     and greatest(
           s.created_at,
           coalesce((select max(d.created_at)  from session_drinks d  where d.session_id  = s.id), s.created_at),
           coalesce((select max(st.arrived_at) from session_stops st  where st.session_id = s.id), s.created_at),
           coalesce((select max(sn.created_at) from session_snaps sn  where sn.session_id = s.id), s.created_at)
         ) < now() - interval '8 hours';
exception when others then
  return;
end $$;

-- cron.schedule by name replaces an existing job of that name.
select cron.schedule('group-autoend', '*/10 * * * *', $$select private.run_group_autoend()$$);
