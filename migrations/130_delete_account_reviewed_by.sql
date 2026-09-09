-- 130_delete_account_reviewed_by.sql
--
-- Account deletion could fail for an admin.
--
-- delete_account_rows nulls the two NO ACTION references that would otherwise
-- block the cascade (venue_push_log.sent_by, event_members.invited_by). Two
-- more of the same shape arrived later with the business portal and were never
-- added: businesses.reviewed_by and business_orders.reviewed_by, both
-- NO ACTION to profiles.
--
-- Only an account that has reviewed a business carries those references, which
-- in practice means an admin. Deleting one raised a foreign key violation on
-- `delete from auth.users` — and by then the delete-account Edge Function had
-- already removed the user's storage files, so the account was left with its
-- photos gone and its rows intact.
--
-- Same treatment as the other two: null the reviewer, keep the review.

create or replace function public.delete_account_rows(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_uid is null then raise exception 'bad_uid'; end if;
  -- Defense in depth: a JWT-bearing caller (auth.uid() set) may only delete
  -- itself. service_role/cron has a null auth.uid() and is trusted.
  if auth.uid() is not null and p_uid <> auth.uid() then
    raise exception 'forbidden';
  end if;
  -- FK-less or NO ACTION references that would survive (or block) the cascade
  update venue_push_log  set sent_by     = null where sent_by     = p_uid;
  update event_members   set invited_by  = null where invited_by  = p_uid;
  update businesses      set reviewed_by = null where reviewed_by = p_uid;
  update business_orders set reviewed_by = null where reviewed_by = p_uid;
  delete from dm_messages where sender_id = p_uid or recipient_id = p_uid;
  delete from events where host_id = p_uid;   -- members cascade with the event
  -- everything else: auth.users -> profiles -> the app, all ON DELETE CASCADE
  delete from auth.users where id = p_uid;
end $$;
revoke all on function public.delete_account_rows(uuid) from public;
grant execute on function public.delete_account_rows(uuid) to service_role;

notify pgrst, 'reload schema';
