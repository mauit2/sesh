-- 010_device_tokens.sql
--
-- Stores APNs (and, later, other platform) device tokens so the server can
-- push a real notification to a user's phone when they're invited to a sesh.
-- Until now invites were discovered only by the in-app 7s poll in
-- InvitesService, which means a locked / closed phone never finds out. This
-- table is the recipient side of that gap; a Supabase Edge Function (added
-- once the paid Apple Developer account + APNs .p8 key are available) reads
-- it to know where to send the push.
--
-- Design:
--
--   • One row per (device token). A token is globally unique — Apple issues
--     it per app-install, not per user — so the PRIMARY uniqueness is on
--     `token`. When a different user signs in on the same device, the row's
--     `user_id` is reassigned to them (handled by the register RPC below),
--     so we never push a previous user's invites to the current user.
--
--   • `user_id` FK cascades on profile delete so a removed account doesn't
--     leave dangling push targets.
--
--   • RLS lets a user read/delete only their own tokens. Writes go through
--     `register_device_token`, a SECURITY DEFINER function (same pattern as
--     `join_session_by_code` in migration 007) so token *reassignment*
--     across users doesn't trip the per-row update policy — the function
--     always stamps `auth.uid()`, so a client can never register a token
--     against someone else's id.

create table if not exists device_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  token       text not null unique,
  platform    text not null default 'ios',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists device_tokens_user_id_idx on device_tokens(user_id);

alter table device_tokens enable row level security;

-- A user can see their own registered devices (useful for a future
-- "manage devices" screen) ...
create policy device_tokens_select_own
  on device_tokens for select
  to authenticated
  using ( user_id = auth.uid() );

-- ... and remove them (e.g. on explicit logout of a device).
create policy device_tokens_delete_own
  on device_tokens for delete
  to authenticated
  using ( user_id = auth.uid() );

-- Registration / reassignment goes through this function rather than a
-- direct INSERT so the upsert can move a token between users without
-- needing an UPDATE policy that would otherwise have to expose other
-- users' rows. SECURITY DEFINER runs it as the table owner; the body
-- always uses auth.uid(), so callers can only ever register the token
-- to *themselves*.
create or replace function register_device_token(p_token text, p_platform text default 'ios')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into device_tokens (user_id, token, platform, updated_at)
  values (auth.uid(), p_token, p_platform, now())
  on conflict (token)
  do update set user_id    = excluded.user_id,
                platform   = excluded.platform,
                updated_at = now();
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default; strip that so only
-- signed-in users can register a token (anon callers would only hit the
-- not-authenticated raise anyway, but this is the clean lock-down).
revoke execute on function register_device_token(text, text) from public;
revoke execute on function register_device_token(text, text) from anon;
grant  execute on function register_device_token(text, text) to authenticated;
