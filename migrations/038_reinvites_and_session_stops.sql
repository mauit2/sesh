-- 038_reinvites_and_session_stops.sql
--
-- Two fixes surfaced by group testing:
--
-- 1. RE-INVITES: invites are unique per (session, recipient), and the send
--    path upserts. But UPDATE was recipient-only, so re-inviting someone
--    who had already accepted/declined was silently swallowed — the
--    recipient never saw a new invite. Senders may now update their own
--    invites (the client resets status to 'pending' on re-send).
--
-- 2. GROUP ROUTE: the group's shared check-ins only lived in each device's
--    local journey, so a member who didn't witness a stop (or whose local
--    journey was empty) got a group recap with no route. session_stops
--    records the group's venue history server-side; whoever checks the
--    group in/out writes it, and every member's group recap reads it.

drop policy if exists invites_update_sender on invites;
create policy invites_update_sender on invites
  for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

create table if not exists session_stops (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references sessions(id) on delete cascade,
  name        text not null,
  lat         double precision,
  lon         double precision,
  arrived_at  timestamptz not null default now(),
  departed_at timestamptz
);

create index if not exists session_stops_session_idx on session_stops (session_id);

alter table session_stops enable row level security;

drop policy if exists session_stops_member_select on session_stops;
create policy session_stops_member_select on session_stops
  for select to authenticated using (is_session_member(session_id));
drop policy if exists session_stops_member_insert on session_stops;
create policy session_stops_member_insert on session_stops
  for insert to authenticated with check (is_session_member(session_id));
drop policy if exists session_stops_member_update on session_stops;
create policy session_stops_member_update on session_stops
  for update to authenticated
  using (is_session_member(session_id))
  with check (is_session_member(session_id));

grant select, insert, update on session_stops to authenticated;
