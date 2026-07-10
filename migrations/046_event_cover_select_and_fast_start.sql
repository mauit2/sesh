-- 046_event_cover_select_and_fast_start.sql
--
-- 1. Cover uploads STILL failed after 045: the client uploads with
--    upsert, and storage-api runs INSERT ... ON CONFLICT DO UPDATE ...
--    RETURNING. Postgres requires the row to pass SELECT policies for
--    both the conflict lookup and the RETURNING projection — and
--    event-covers had no SELECT policy at all (reads go through the
--    public-bucket path, so nobody noticed). Reproduced 1:1 in SQL:
--    plain INSERT passes, the upsert form violates RLS. Fix: a bucket-
--    scoped SELECT policy (the bucket is public anyway — this leaks
--    nothing).
--
-- 2. Auto-start felt broken: the lifecycle cron ran every 5 minutes, so
--    an event created to start "in one minute" sat idle for up to four
--    more. The job now runs every minute, and authenticated clients may
--    invoke the (idempotent) lifecycle function directly — EventsService
--    kicks it the moment it sees a due, armed, unstarted event, so the
--    sesh starts on the next poll instead of the next cron tick.

drop policy if exists event_covers_select on storage.objects;
create policy event_covers_select on storage.objects
  for select to authenticated
  using (bucket_id = 'event-covers');

-- Lifecycle every minute (idempotent function, trivial cost).
do $$
begin
  perform cron.unschedule('event-live-lifecycle');
exception when others then
  null;
end $$;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'event-live-lifecycle') then
    perform cron.schedule('event-live-lifecycle', '* * * * *',
                          'select public.run_event_live_lifecycle()');
  end if;
end $$;

-- Clients may kick the lifecycle directly (it only starts events whose
-- time has come and ends sessions whose conditions are met — no user
-- input flows into it, so this is safe to expose).
grant execute on function public.run_event_live_lifecycle() to authenticated;
