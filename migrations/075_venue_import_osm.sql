-- 075_venue_import_osm.sql — room for the bulk OSM venue import.
--
-- "add all the bars, pubs and restaurants please". Central Gothenburg has ~1270
-- named venues in OpenStreetMap; filtered to bar / pub / nightclub / biergarten
-- / restaurant (i.e. excluding the 254 cafés) that is ~1000, and 1002 were
-- imported, taking the table from 42 rows to 1044.
--
-- Two schema changes were needed, plus one consequence:

-- 1. Provenance. 'osm' was not an allowed source, and provenance matters here:
--    an OSM row is community data (ODbL, attribution required) rather than
--    something we curated or a user typed in.
alter table venues drop constraint if exists venues_source_check;
alter table venues add constraint venues_source_check
  check (source = any (array['curated'::text, 'mapkit'::text, 'user'::text, 'osm'::text]));

-- 2. The Sun map draws one annotation per reading, so at ~1000 venues it would
--    try to render a thousand pins: slow, and unreadable. Return the NEAREST
--    p_limit instead, keeping the map dense but legible around the user.
create or replace function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 150
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
    and coalesce(c.reason, 'unique') <> 'duplicate'
  order by haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit greatest(1, least(p_limit, 400));
$$;

grant execute on function venue_sun_map(double precision, double precision, double precision, integer) to authenticated;

-- 3. Re-run the duplicate map after any import: the guard below is applied at
--    insert time, but new rows can still collide with each other. This went
--    from 5 hidden duplicates to 9 after the import.
select refresh_venue_canonical();

notify pgrst, 'reload schema';

-- HOW THE IMPORT RAN
--
-- The `venue-import` Edge Function (supabase/functions/venue-import) is the
-- re-runnable way to do this for any city:
--   POST { "bbox": [south, west, north, east], "city": "…", "dry_run": true }
-- It pulls named venues from Overpass and inserts the ones we lack, skipping
-- anything whose OSM id we already stored and anything with the same name
-- within 150 m of an existing venue (so the app's own MapKit-resolved rows and
-- an OSM row don't both land). It is deliberately NOT deduped on name alone:
-- two branches of one chain are two venues.
--
-- For THIS run, Overpass refused the Edge Function's egress IP (overpass_
-- unavailable on both mirrors, repeatedly), so the fetch was done from Postgres
-- with pg_net instead and parsed straight out of net._http_response — which
-- also means the payload never had to be shipped through a client:
--
--   select net.http_get('https://overpass-api.de/api/interpreter?data=' ||
--     <url-encoded Overpass QL>, timeout_milliseconds := 180000);
--   -- then, once net._http_response has the 200:
--   insert into venues (name, address, city, lat, lon, source, external_id)
--   with src as (select jsonb_array_elements((content::jsonb)->'elements') as e
--                from net._http_response where id = <request id>) ...
--
-- The full statement, including the node/way collapse
-- (distinct on (lower(name), round(lat,3), round(lon,3)) — OSM often has both a
-- node and a building way for one venue) and the two dedupe guards, is in the
-- function; mirror it there if you re-run by hand.
