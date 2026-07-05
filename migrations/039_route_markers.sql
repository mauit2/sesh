-- 039_route_markers.sql
--
-- The group route (session_stops, migration 038) so far only recorded
-- venue check-ins. The group recap must show EVERYTHING anyone logged —
-- pre-game spots, between-bars stops, food/puke markers — including stops
-- from before a member joined. Members now mirror their journey markers
-- into the route (client upserts keyed by the journey stop's own uuid),
-- so: add a kind + who logged it.

alter table session_stops add column if not exists kind text not null default 'bar';
alter table session_stops add column if not exists profile_id uuid references profiles(id) on delete set null;
