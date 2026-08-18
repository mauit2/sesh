-- 106: close the anon/authenticated over-grant on privileged functions.
--
-- ROOT CAUSE: Supabase's project default privileges auto-grant EXECUTE on
-- every new function to anon + authenticated. Migrations that only did
-- `revoke ... from public` never revoked those two roles, so functions the
-- authors believed were locked to service_role/authenticated were reachable
-- by anyone holding the public anon key. This migration (a) revokes that
-- default going forward and (b) fixes the four functions that had no internal
-- caller guard. Functions with their own is_app_admin()/auth.uid() checks are
-- left as-is; they fail safe.

-- (HIGH) stop future functions from being auto-exposed to the public roles.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;

-- (CRITICAL) delete_account_rows: only the delete-account edge function calls
-- it, with service_role, after verifying the caller's JWT. No client path.
-- Revoke both public roles AND add a self-guard so that even a future
-- authenticated grant can only ever delete the caller's own account.
revoke execute on function public.delete_account_rows(uuid) from anon, authenticated;

create or replace function public.delete_account_rows(p_uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_uid is null then raise exception 'bad_uid'; end if;
  -- Defense in depth: a JWT-bearing caller (auth.uid() set) may only delete
  -- itself. service_role/cron has a null auth.uid() and is trusted.
  if auth.uid() is not null and p_uid <> auth.uid() then
    raise exception 'forbidden';
  end if;
  update venue_push_log set sent_by = null where sent_by = p_uid;
  update event_members set invited_by = null where invited_by = p_uid;
  delete from dm_messages where sender_id = p_uid or recipient_id = p_uid;
  delete from events where host_id = p_uid;
  delete from auth.users where id = p_uid;
end $function$;

revoke execute on function public.delete_account_rows(uuid) from anon, authenticated;
grant  execute on function public.delete_account_rows(uuid) to service_role;

-- (MEDIUM) run_event_live_lifecycle: the app calls it as an authenticated
-- user to advance auto-live events; anon has no business triggering pushes.
revoke execute on function public.run_event_live_lifecycle() from anon;

-- (LOW) set_venue_time_zone: authenticated-only backfill; drop anon.
revoke execute on function public.set_venue_time_zone(uuid, text) from anon;

-- (LOW) purge_rate_limits: housekeeping, no client caller — service_role only.
revoke execute on function public.purge_rate_limits() from anon, authenticated;
