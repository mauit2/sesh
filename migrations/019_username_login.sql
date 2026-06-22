-- 019_username_login.sql
--
-- Supporting RPCs for (a) live username-availability checks during sign-up
-- and (b) username sign-in via the `username-login` Edge Function.

-- Public availability check used by the sign-up form. Returns true only for
-- a well-formed, unclaimed username. Safe to expose (usernames are public
-- handles; this reveals nothing an eventual sign-up attempt wouldn't).
create or replace function username_available(p_username text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select case
    when lower(trim(p_username)) !~ '^[a-z0-9_]{3,20}$' then false
    else not exists (select 1 from profiles where lower(username) = lower(trim(p_username)))
  end;
$$;

revoke execute on function username_available(text) from public;
grant  execute on function username_available(text) to anon, authenticated;

-- Resolve a username to its account email. Reads auth.users, so it's
-- SECURITY DEFINER — and granted ONLY to service_role so it is NOT reachable
-- from the public (anon/authenticated) API. The `username-login` Edge
-- Function calls it with the service-role key; the email is used server-side
-- to sign in and is never returned to the client.
create or replace function email_for_username(p_username text)
returns text
language sql
security definer
set search_path = public, auth
as $$
  select u.email
  from auth.users u
  join profiles p on p.id = u.id
  where lower(p.username) = lower(trim(p_username))
  limit 1;
$$;

revoke execute on function email_for_username(text) from public, anon, authenticated;
grant  execute on function email_for_username(text) to service_role;

notify pgrst, 'reload schema';
