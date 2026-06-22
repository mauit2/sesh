-- 018_friends.sql
--
-- In-app friends so users can build a roster once and invite people to a
-- sesh in a tap (instead of needing someone's profile id from a live group).
--
-- People are found by a unique @username (added to profiles here). Friend
-- relationships live in `friendships` (a request -> accept flow). profiles'
-- RLS only exposes your own row + session peers, so every cross-user lookup
-- (username search, friend rosters) goes through member-authorized
-- SECURITY DEFINER RPCs — mirroring grant_admin_by_email / join_session_by_code.

-- ---------------------------------------------------------------------
-- Usernames on profiles
-- ---------------------------------------------------------------------

alter table profiles add column if not exists username text;

-- Case-insensitive uniqueness without the citext extension. NULLs are
-- allowed (existing accounts until they pick one); Postgres permits many
-- NULLs under a unique index.
create unique index if not exists profiles_username_lower_idx
  on profiles (lower(username));

-- Format: 3–20 chars, lowercase letters / digits / underscore. NULL ok.
alter table profiles drop constraint if exists profiles_username_format;
alter table profiles add constraint profiles_username_format
  check (username is null or username ~ '^[a-z0-9_]{3,20}$');

-- ---------------------------------------------------------------------
-- Friendships
-- ---------------------------------------------------------------------

create table if not exists friendships (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null references profiles(id) on delete cascade,
  addressee_id  uuid not null references profiles(id) on delete cascade,
  status        text not null default 'pending'
                check (status in ('pending', 'accepted')),
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,
  check (requester_id <> addressee_id),
  unique (requester_id, addressee_id)
);

-- Incoming requests for a user ("who wants to friend me"), and the reverse
-- direction lookup used when resolving a request to auto-accept a mutual.
create index if not exists friendships_addressee_idx
  on friendships (addressee_id, status);
create index if not exists friendships_requester_idx
  on friendships (requester_id, status);

alter table friendships enable row level security;

-- Read: either party can see a row they're part of. All writes go through
-- the RPCs below (no direct insert/update/delete policies).
drop policy if exists friendships_select_own on friendships;
create policy friendships_select_own
  on friendships for select
  to authenticated
  using ( requester_id = auth.uid() or addressee_id = auth.uid() );

-- ---------------------------------------------------------------------
-- RPCs (SECURITY DEFINER, authenticated-only)
-- ---------------------------------------------------------------------

-- Set / change the caller's username. Validates format + case-insensitive
-- uniqueness. Returns { ok, reason?, username? }.
create or replace function set_username(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_clean text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_clean := lower(trim(p_username));
  if v_clean !~ '^[a-z0-9_]{3,20}$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if exists (select 1 from profiles where lower(username) = v_clean and id <> auth.uid()) then
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end if;
  update profiles set username = v_clean where id = auth.uid();
  return jsonb_build_object('ok', true, 'username', v_clean);
end;
$$;

-- Prefix search for the add-friend screen. Returns up to 10 matches with a
-- `relation` flag (none/friend/outgoing/incoming) so the UI can label them.
-- Excludes the caller and users without a username.
create or replace function search_usernames(p_query text)
returns table (id uuid, name text, username text, avatar_url text, relation text)
language plpgsql
security definer
set search_path = public
as $$
declare v_q text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_q := lower(trim(p_query));
  if length(v_q) < 1 then return; end if;
  return query
    select p.id, p.name, p.username, p.avatar_url,
      case
        when exists (select 1 from friendships f where f.status='accepted'
              and ((f.requester_id=auth.uid() and f.addressee_id=p.id)
                or (f.requester_id=p.id and f.addressee_id=auth.uid()))) then 'friend'
        when exists (select 1 from friendships f where f.status='pending'
              and f.requester_id=auth.uid() and f.addressee_id=p.id) then 'outgoing'
        when exists (select 1 from friendships f where f.status='pending'
              and f.requester_id=p.id and f.addressee_id=auth.uid()) then 'incoming'
        else 'none'
      end as relation
    from profiles p
    where p.username is not null
      and p.id <> auth.uid()
      and lower(p.username) like v_q || '%'
    order by p.username
    limit 10;
end;
$$;

-- Send a friend request by username. Auto-accepts if the target already
-- has a pending request to the caller (mutual). Returns { ok, status?, reason? }.
create or replace function send_friend_request(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_target uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username)) limit 1;
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_target = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'self'); end if;

  if exists (select 1 from friendships where status='accepted'
        and ((requester_id=auth.uid() and addressee_id=v_target)
          or (requester_id=v_target and addressee_id=auth.uid()))) then
    return jsonb_build_object('ok', false, 'reason', 'already_friends');
  end if;

  -- They already asked us -> accept the mutual.
  if exists (select 1 from friendships where status='pending'
        and requester_id=v_target and addressee_id=auth.uid()) then
    update friendships set status='accepted', responded_at=now()
      where requester_id=v_target and addressee_id=auth.uid();
    return jsonb_build_object('ok', true, 'status', 'accepted');
  end if;

  insert into friendships (requester_id, addressee_id, status)
    values (auth.uid(), v_target, 'pending')
    on conflict (requester_id, addressee_id) do nothing;
  return jsonb_build_object('ok', true, 'status', 'pending');
end;
$$;

-- Accept (-> accepted) or decline (-> row deleted, so it can be re-sent) an
-- incoming request. Only the addressee may act.
create or replace function respond_friend_request(p_request_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_accept then
    update friendships set status='accepted', responded_at=now()
      where id=p_request_id and addressee_id=auth.uid() and status='pending';
  else
    delete from friendships
      where id=p_request_id and addressee_id=auth.uid() and status='pending';
  end if;
end;
$$;

-- Unfriend (or cancel an outgoing request) — removes the row in either
-- direction between the caller and the other user.
create or replace function remove_friend(p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from friendships
    where (requester_id=auth.uid() and addressee_id=p_other)
       or (requester_id=p_other and addressee_id=auth.uid());
end;
$$;

-- The caller's accepted friends, with the OTHER person's public fields.
create or replace function list_friends()
returns table (friendship_id uuid, id uuid, name text, username text, avatar_url text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return query
    select f.id, p.id, p.name, p.username, p.avatar_url
    from friendships f
    join profiles p on p.id = case when f.requester_id=auth.uid() then f.addressee_id else f.requester_id end
    where f.status='accepted' and (f.requester_id=auth.uid() or f.addressee_id=auth.uid())
    order by p.name;
end;
$$;

-- Pending requests addressed to the caller, with the requester's fields.
create or replace function list_incoming_requests()
returns table (request_id uuid, id uuid, name text, username text, avatar_url text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return query
    select f.id, p.id, p.name, p.username, p.avatar_url, f.created_at
    from friendships f
    join profiles p on p.id = f.requester_id
    where f.status='pending' and f.addressee_id=auth.uid()
    order by f.created_at desc;
end;
$$;

revoke execute on function set_username(text)               from public, anon;
revoke execute on function search_usernames(text)           from public, anon;
revoke execute on function send_friend_request(text)        from public, anon;
revoke execute on function respond_friend_request(uuid, boolean) from public, anon;
revoke execute on function remove_friend(uuid)              from public, anon;
revoke execute on function list_friends()                   from public, anon;
revoke execute on function list_incoming_requests()         from public, anon;
grant execute on function set_username(text)                to authenticated;
grant execute on function search_usernames(text)            to authenticated;
grant execute on function send_friend_request(text)         to authenticated;
grant execute on function respond_friend_request(uuid, boolean) to authenticated;
grant execute on function remove_friend(uuid)               to authenticated;
grant execute on function list_friends()                    to authenticated;
grant execute on function list_incoming_requests()          to authenticated;

notify pgrst, 'reload schema';
