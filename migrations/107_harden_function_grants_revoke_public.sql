-- 107: follow-up to 106. Postgres grants EXECUTE to PUBLIC at function
-- creation, so anon still inherited execute on these three via PUBLIC even
-- after the explicit anon revoke. Revoke PUBLIC and re-grant only the roles
-- that actually call each function (verified against the client + edge code).

-- app calls it as an authenticated user; cron/service too. Not anon.
revoke execute on function public.run_event_live_lifecycle() from public;
grant  execute on function public.run_event_live_lifecycle() to authenticated, service_role;

-- app (Sun.swift) calls it as authenticated. Not anon.
revoke execute on function public.set_venue_time_zone(uuid, text) from public;
grant  execute on function public.set_venue_time_zone(uuid, text) to authenticated, service_role;

-- housekeeping, no client caller. service_role only.
revoke execute on function public.purge_rate_limits() from public;
grant  execute on function public.purge_rate_limits() to service_role;
