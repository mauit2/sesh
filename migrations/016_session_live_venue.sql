-- 016_session_live_venue.sql
--
-- Group check-in: one member can check the whole group into a venue, so
-- not everyone has to check in individually. The current group venue rides
-- on the session row as JSONB (null = the group is checked out), so the
-- existing 3s session poll distributes it. Members who are "following the
-- group" adopt it; members who "broke away" manage their own local venue.
--
-- Member-authorized via a SECURITY DEFINER RPC (mirrors set_session_ghosts)
-- because sessions' RLS update policy is host-only.
--
-- Shape mirrors the app's Venue Codable:
--   { "id": uuid, "name": text, "address": text?, "city": text?,
--     "lat": double, "lon": double, "is_featured": bool,
--     "source": text, "external_id": text?, "created_at": iso8601 }
alter table sessions
  add column if not exists live_venue jsonb;

create or replace function set_session_live_venue(p_session_id uuid, p_venue jsonb)
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
     set live_venue = p_venue
   where id = p_session_id;
end;
$$;

revoke execute on function set_session_live_venue(uuid, jsonb) from public;
revoke execute on function set_session_live_venue(uuid, jsonb) from anon;
grant  execute on function set_session_live_venue(uuid, jsonb) to authenticated;
