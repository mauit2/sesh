-- 052_push_badge.sql
--
-- App-icon badge on push. `notify_push` now stamps every push with the
-- recipient's total unseen ACTIONABLE items, so a locked or fully-closed phone
-- shows the number without the app having to run (APNs sets the badge from the
-- payload at the OS level).
--
-- The badge counts what the server actually tracks as unseen:
--   unread DMs + pending sesh invites + pending event invites + friend requests.
-- Likes/comments are "activity" (the in-app bell), have no server-side
-- seen-state, and so do not move the badge — the badge stays an accurate count
-- of your actionable inbox. The client-side AppBadgeModifier additionally folds
-- in new Nightline posts while the app is running.
--
-- Cost: read-only COUNTs on small tables inside the EXISTING trigger path — no
-- new storage, no extra egress (the count never leaves the DB; only ~10 bytes
-- of `"badge":N` ride along on the APNs request the function already sends), and
-- no additional edge-function invocations.
--
-- Pairs with the send-push Edge Function, which reads an optional `badge` field
-- from the request body and includes it as `aps.badge` when present.

create or replace function private.unseen_count(p_user uuid)
returns int
language sql security definer set search_path = public, private stable as $$
  select (
      (select count(*) from dm_messages   where recipient_id = p_user and read_at is null)
    + (select count(*) from invites       where recipient_id = p_user and status = 'pending')
    + (select count(*) from event_members where profile_id   = p_user and status = 'pending')
    + (select count(*) from friendships   where addressee_id = p_user and status = 'pending')
  )::int;
$$;

create or replace function private.notify_push(
  p_user uuid, p_title text, p_body text, p_data jsonb
) returns void
language plpgsql security definer set search_path = public, private as $$
declare cfg private.push_config;
begin
  if p_user is null then return; end if;
  select * into cfg from private.push_config where id = 1;
  if cfg.function_url is null then return; end if;
  perform net.http_post(
    url     := cfg.function_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || cfg.secret),
    body    := jsonb_build_object(
                 'user_id', p_user, 'title', p_title, 'body', p_body, 'data', p_data,
                 'badge', private.unseen_count(p_user))
  );
exception when others then
  -- never let a push failure break the triggering write
  return;
end; $$;
