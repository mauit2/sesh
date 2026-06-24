-- 028_push_notifications.sql
--
-- Server-side push: fires an APNs notification (via the `send-push` Edge
-- Function) when someone likes/comments on the caller's post, sends a friend
-- request, or sends a sesh invite. These mirror the in-app bell so a locked or
-- closed phone still finds out.
--
-- Mechanics:
--   • pg_net makes the async HTTP call to the function from AFTER INSERT
--     triggers, so the user's action never waits on (or fails because of) the
--     push.
--   • The function is guarded by a shared secret. We keep the secret + the
--     function URL in a `private` schema that anon/authenticated cannot read,
--     and the SECURITY DEFINER trigger fn reads it. The same secret value must
--     be set as the `PUSH_HOOK_SECRET` Edge Function secret.
--   • notify_push swallows any error so a push problem can't roll back the
--     like/comment/invite that triggered it.

create extension if not exists pg_net;

create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table if not exists private.push_config (
  id           int primary key default 1,
  function_url text not null,
  secret       text not null,
  constraint push_config_singleton check (id = 1)
);
revoke all on table private.push_config from anon, authenticated;

insert into private.push_config (id, function_url, secret)
values (
  1,
  'https://lltuozmbxacxiepardys.supabase.co/functions/v1/send-push',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
)
on conflict (id) do nothing;

-- Core helper: POST {user_id,title,body,data} to the Edge Function.
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
                 'user_id', p_user, 'title', p_title, 'body', p_body, 'data', p_data)
  );
exception when others then
  -- never let a push failure break the triggering write
  return;
end; $$;

-- Like → notify post author
create or replace function on_like_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_author uuid; v_name text;
begin
  select author_id into v_author from posts where id = NEW.post_id;
  if v_author is null or v_author = NEW.user_id then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.user_id;
  perform private.notify_push(
    v_author, 'New like', coalesce(v_name,'Someone') || ' liked your night',
    jsonb_build_object('type','like','post_id', NEW.post_id));
  return NEW;
end; $$;

-- Comment → notify post author
create or replace function on_comment_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_author uuid; v_name text;
begin
  select author_id into v_author from posts where id = NEW.post_id;
  if v_author is null or v_author = NEW.author_id then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.author_id;
  perform private.notify_push(
    v_author, 'New comment', coalesce(v_name,'Someone') || ' commented on your night',
    jsonb_build_object('type','comment','post_id', NEW.post_id));
  return NEW;
end; $$;

-- Friend request → notify addressee
create or replace function on_friend_request_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_name text;
begin
  if NEW.status <> 'pending' then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.requester_id;
  perform private.notify_push(
    NEW.addressee_id, 'Friend request',
    coalesce(v_name,'Someone') || ' wants to be friends',
    jsonb_build_object('type','friend_request'));
  return NEW;
end; $$;

-- Sesh invite → notify recipient
create or replace function on_invite_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_name text;
begin
  if NEW.recipient_id is null then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.sender_id;
  perform private.notify_push(
    NEW.recipient_id, 'Sesh invite',
    coalesce(v_name,'Someone') || ' invited you to a sesh',
    jsonb_build_object('type','invite','session_id', NEW.session_id));
  return NEW;
end; $$;

drop trigger if exists trg_like_notify    on post_likes;
drop trigger if exists trg_comment_notify on post_comments;
drop trigger if exists trg_friend_notify  on friendships;
drop trigger if exists trg_invite_notify  on invites;

create trigger trg_like_notify    after insert on post_likes
  for each row execute function on_like_notify();
create trigger trg_comment_notify after insert on post_comments
  for each row execute function on_comment_notify();
create trigger trg_friend_notify  after insert on friendships
  for each row execute function on_friend_request_notify();
create trigger trg_invite_notify  after insert on invites
  for each row execute function on_invite_notify();
