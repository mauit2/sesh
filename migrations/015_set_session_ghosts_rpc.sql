-- 015_set_session_ghosts_rpc.sql
--
-- Bugfix: a manually-added guest disappeared right after being added.
-- syncGhosts wrote the guest roster with a direct UPDATE on `sessions`,
-- but that table's RLS update policy is host-only (sessions_update_host),
-- so a non-host member's write silently failed and the next 3s poll wiped
-- the local guest with the stale empty server value.
--
-- Fix: route guest writes through this SECURITY DEFINER RPC, authorized by
-- session membership (the same is_session_member helper the RLS policies
-- use), so any member can update just the `ghosts` column. (The client
-- also now suppresses the poll's ghost-overwrite while a write is in
-- flight, to kill the host-side race.)
create or replace function set_session_ghosts(p_session_id uuid, p_ghosts jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_session_member(p_session_id) then
    raise exception 'not a session member';
  end if;
  update sessions
     set ghosts = coalesce(p_ghosts, '[]'::jsonb)
   where id = p_session_id;
end;
$$;

revoke execute on function set_session_ghosts(uuid, jsonb) from public;
revoke execute on function set_session_ghosts(uuid, jsonb) from anon;
grant  execute on function set_session_ghosts(uuid, jsonb) to authenticated;
