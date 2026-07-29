-- 068_delete_account.sql
--
-- In-app account deletion (App Store guideline 5.1.1(v) — required for any
-- app with account creation).
--
-- Architecture note: Supabase blocks direct SQL deletes on storage.objects
-- (protect_delete trigger), so deletion is split in two. The `delete-account`
-- Edge Function verifies the caller's JWT, removes their files via the
-- Storage API (paths listed by user_files), then calls delete_account_rows.
-- Both SQL helpers are service_role-only; clients can only reach them through
-- the function, and only for themselves.
--
-- Community data policy: the user's beer prices stay on the map, detached
-- (user_id -> null), matching migration 066 which already made web
-- submissions anonymous. Everything personal — sessions, drinks, stories,
-- snaps, DMs, events, friendships, uploaded files — is deleted.

-- A deleted account should not take its beer prices with it.
alter table beer_prices drop constraint beer_prices_user_id_fkey;
alter table beer_prices add constraint beer_prices_user_id_fkey
  foreign key (user_id) references profiles(id) on delete set null;

-- Every file the user owns, for the Edge Function to remove via Storage API.
create or replace function public.user_files(p_uid uuid)
returns table (bucket_id text, name text)
language sql stable security definer set search_path = public as $$
  select o.bucket_id, o.name from storage.objects o where o.owner = p_uid;
$$;
revoke all on function public.user_files(uuid) from public;
grant execute on function public.user_files(uuid) to service_role;

create or replace function public.delete_account_rows(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_uid is null then raise exception 'bad_uid'; end if;
  -- FK-less or NO ACTION references that would survive (or block) the cascade
  update venue_push_log set sent_by = null where sent_by = p_uid;
  update event_members set invited_by = null where invited_by = p_uid;
  delete from dm_messages where sender_id = p_uid or recipient_id = p_uid;
  delete from events where host_id = p_uid;   -- members cascade with the event
  -- everything else: auth.users -> profiles -> the app, all ON DELETE CASCADE
  delete from auth.users where id = p_uid;
end $$;
revoke all on function public.delete_account_rows(uuid) from public;
grant execute on function public.delete_account_rows(uuid) to service_role;

notify pgrst, 'reload schema';
