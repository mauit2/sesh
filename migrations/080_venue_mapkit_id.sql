-- 080_venue_mapkit_id.sql — tie venues to Apple Maps.
--
-- WHY A SEPARATE COLUMN. external_id is already load-bearing: OSM-imported rows
-- hold 'osm:node/123' there and the venue-import function dedupes on it, so
-- overwriting it with an Apple id would make every re-import create duplicates.
-- mapkit_id coexists with an OSM id on the same row.
--
-- WHY THE IDs ARE COMPATIBLE. Values come from the Apple Maps Server API, whose
-- place `id` is the same identifier space as MKMapItem.identifier on device.
-- Verified rather than assumed: a server-side search for Bar Etzy returned
-- IED9B72FB5F82A87D, matching the I+16-hex format the app was already storing
-- from on-device MKLocalSearch. That means a venue resolved server-side and one
-- resolved in the app dedupe against each other instead of doubling up.

alter table venues add column if not exists mapkit_id text;
alter table venues add column if not exists mapkit_checked_at timestamptz;

comment on column venues.mapkit_id is
  'Apple Maps place id (same space as MKMapItem.identifier). Null = unresolved; see mapkit_checked_at for whether we tried.';
comment on column venues.mapkit_checked_at is
  'When Apple Maps was last asked about this venue, hit or miss — stops us re-querying misses forever.';

-- One Apple place = one venue. This constraint is also what surfaced genuine
-- duplicates: two of our rows resolving to the same place means one bar entered
-- the database twice.
create unique index if not exists venues_unique_mapkit_id
  on venues (mapkit_id) where mapkit_id is not null;

-- Rows that already carried an Apple id in external_id (resolved in-app).
update venues
   set mapkit_id = external_id,
       mapkit_checked_at = now()
 where mapkit_id is null
   and external_id is not null
   and external_id ~ '^I[0-9A-F]{16}$';

notify pgrst, 'reload schema';

-- HOW THE BACKFILL RAN
--
-- scripts (kept out of the repo, in the session scratchpad): probe.mjs signs an
-- ES256 JWT with the MapKit .p8 that lives at ~/Developer/sesh_app/ and never in
-- this repo, exchanges it at https://maps-api.apple.com/v1/token, then searches
-- /v1/search per venue. run.mjs drives it over the whole table.
--
-- MATCHING IS STRICT, because a wrong link is worse than no link: the unique
-- index above would then block the correct venue from ever claiming that place.
-- Two independent checks must BOTH pass:
--   * name similarity >= 0.72   (Dice coefficient on accent-folded bigrams, so
--                                "John Scott's Pub" matches "John Scotts Pub"
--                                but not "John's Place")
--   * distance <= 300 m         (Apple's coordinate vs ours)
-- Ties break on distance, which is what correctly gave the two Bastard Burgers
-- branches different ids rather than collapsing them into one.
--
-- RESULT: scanned 1089, matched 771, wrote 751. The 20-row gap is venues whose
-- Apple place was already claimed by another of our rows — i.e. duplicates.
--
-- COORDINATES: only overwritten for source in ('curated','user'). Those are the
-- hand-seeded rows that were demonstrably wrong (Handelspuben sat ~1 km from its
-- own address). OSM geometry is surveyed and left alone.
--
-- The write channel used during the backfill (apply_mapkit_ids, guarded by a
-- shared secret) was dropped immediately afterwards in 081.
