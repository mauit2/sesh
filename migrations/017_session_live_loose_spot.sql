-- 017_session_live_loose_spot.sql
--
-- Group "loose" location: a pre-game or between-bars spot one member sets
-- can apply to the whole group, just like a bar check-in (migration 016).
-- Members who are following the group adopt it into their own journey.
-- Rides on the session row as JSONB (null = none), distributed by the 3s
-- poll. Member-authorized RPC (sessions' RLS update is host-only).
--
-- Shape mirrors the app's LooseSpot Codable:
--   { "id": uuid, "name": text?, "lat": double?, "lon": double?,
--     "at": iso8601 }
alter table sessions
  add column if not exists live_loose_spot jsonb;

create or replace function set_session_live_loose_spot(p_session_id uuid, p_spot jsonb)
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
     set live_loose_spot = p_spot
   where id = p_session_id;
end;
$$;

revoke execute on function set_session_live_loose_spot(uuid, jsonb) from public;
revoke execute on function set_session_live_loose_spot(uuid, jsonb) from anon;
grant  execute on function set_session_live_loose_spot(uuid, jsonb) to authenticated;
