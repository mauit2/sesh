-- merge_duplicate_venues.sql — NOT APPLIED. Needs an explicit go-ahead.
--
-- STATUS: this physically deletes 5 venue rows from production, so it was left
-- unapplied. The user-visible bug it fixes is ALREADY fixed by
-- 073_venue_canonical.sql, which marks the duplicates and has every read path
-- ignore them — without removing anything. Run this later only if you want the
-- database actually tidied; it repoints all foreign keys first and snapshots
-- every deleted row into venues_dedup_backup, so it stays reversible.
--
-- Original notes follow.
--
-- SYMPTOM: "the locations of some of the bars are inaccurate, for example
-- Handelspuben". Cause was not a bad coordinate transform — it was SIX
-- redundant venue rows, two of which disagreed with their twin about where the
-- place is. The map drew both, so a venue could appear in the wrong spot (and
-- pin labels collided because e.g. John Scott's was drawn twice).
--
--   Handelspuben      x2, 645 m apart, both "Vasagatan 1". Geocoding that
--                     address gives 57.69735,11.96146 — 96 m from the
--                     MapKit-resolved row and ~1 km from the curated one, so
--                     the curated row's coordinate was simply wrong.
--   John Scott's Pub  x2 at an identical coordinate.
--   Moon Thai Kitchen x3 at an identical coordinate.
--   Tacos & Tequila   x2 at an identical coordinate.
--
-- DELIBERATELY NOT MERGED: Port Du Soleil's two rows are 1050 m apart with
-- DIFFERENT addresses (Nya allén 11 / Packhusplatsen 11) and different Apple
-- Maps ids — two real locations of the same name, not a duplicate. Hence the
-- merge key below is "same name AND (within 150 m OR same street address)",
-- which catches Handelspuben without collapsing genuine second locations.
--
-- Survivor per group: the MapKit-resolved row first (its coordinate came from
-- Apple Maps rather than a hand-typed seed), then the oldest. Losers' rows are
-- copied to venues_dedup_backup first, so this is reversible.

begin;

create table if not exists venues_dedup_backup (
  backed_up_at timestamptz not null default now(),
  batch        text not null,
  merged_into  uuid not null,
  row_data     jsonb not null
);

comment on table venues_dedup_backup is
  'Pre-merge snapshots from 073_dedupe_venues.sql. Keep — this is the undo.';

-- 1. Identify losers and snapshot them, in ONE statement. Everything after
--    this reads the pairs back out of the (permanent) backup table rather than
--    a temp table, so the migration is safe whether the runner executes these
--    statements in one session or several.
with norm as (
  select id, lat, lon, external_id, created_at,
         lower(btrim(name)) as nm,
         lower(btrim(regexp_replace(coalesce(address, ''), ',\s*göteborg\s*$', '', 'i'))) as addr
  from venues
),
-- "Is a duplicate of" edges (symmetric).
edges as (
  select a.id as a_id, b.id as b_id
  from norm a
  join norm b on a.nm = b.nm and a.id <> b.id
  where haversine_m(a.lat, a.lon, b.lat, b.lon) <= 150
     or (a.addr = b.addr and a.addr <> '')
),
-- Group key per row. Every duplicate set here is mutually connected, so the
-- smallest id among {self, neighbours} identifies the component.
comp as (
  select a_id as id,
         least(a_id, (select min(e.b_id) from edges e where e.a_id = s.a_id)) as g
  from (select distinct a_id from edges) s
),
-- One survivor per group: MapKit-resolved first, then oldest.
survivor as (
  select c.g,
         (array_agg(v.id order by (v.external_id is null), v.created_at, v.id))[1] as survivor
  from comp c
  join venues v on v.id = c.id
  group by c.g
)
insert into venues_dedup_backup (batch, merged_into, row_data)
select 'm073', s.survivor, to_jsonb(v)
from comp c
join survivor s on s.g = c.g
join venues v on v.id = c.id
where c.id <> s.survivor;

-- 2. Repoint every reference from loser to survivor.
update beer_prices t set venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.venue_id = (b.row_data->>'id')::uuid;
update venue_offers t set venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.venue_id = (b.row_data->>'id')::uuid;
update venue_campaigns t set venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.venue_id = (b.row_data->>'id')::uuid;
update venue_specials t set venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.venue_id = (b.row_data->>'id')::uuid;
update venue_push_log t set venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.venue_id = (b.row_data->>'id')::uuid;
update sessions t set current_venue_id = b.merged_into
  from venues_dedup_backup b
  where b.batch = 'm073' and t.current_venue_id = (b.row_data->>'id')::uuid;

-- 3. Retire the losers. Horizons are keyed to a coordinate and cheap to
--    recompute, so they are cleared here and rebuilt right after.
delete from venue_sun where venue_id in (
  select (row_data->>'id')::uuid from venues_dedup_backup where batch = 'm073');
delete from venues where id in (
  select (row_data->>'id')::uuid from venues_dedup_backup where batch = 'm073');

-- Guards so this can't silently come back.
-- 4 decimal places is ~11 m: same name at the same spot is one venue.
create unique index if not exists venues_unique_name_point
  on venues (lower(btrim(name)), round(lat::numeric, 4), round(lon::numeric, 4));

-- The same Apple Maps POI must only ever produce one row.
create unique index if not exists venues_unique_external_id
  on venues (external_id) where external_id is not null;

commit;
