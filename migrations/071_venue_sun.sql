-- 071_venue_sun.sql — "Where's the sun": per-venue shading horizons.
--
-- NOTE ON HISTORY: this was originally applied to prod directly (as migration
-- `venue_sun_horizons`) and the file was not saved at the time. This is that
-- schema, reconstructed from the live database with pg_get_functiondef, so it
-- is replayable from scratch on a fresh project.
--
-- THE MODEL — a horizon profile. For each venue we store 72 numbers, one per
-- 5° compass bin, each being the highest elevation angle blocked by buildings
-- in that direction (in TENTHS of a degree, so smallint is plenty). A terrace
-- is in direct sun when the sun's altitude exceeds the horizon value in the
-- sun's own azimuth. That makes a whole day of sun/shade a pure client-side
-- array lookup: no network per hour, and it works offline.
--
-- The profiles are computed by the `sun-horizon` Edge Function from Mapbox
-- building footprints + heights (OSM as fallback); see that function for the
-- geometry. `confidence` is the share of contributing buildings that had a
-- real height rather than an estimate, and `source` records which provider
-- backed it, so the UI can be honest about how good a given profile is.

create table if not exists venue_sun (
  venue_id    uuid primary key references venues(id) on delete cascade,
  -- 72 bins x 5°, tenths of a degree of blocked elevation.
  horizon     smallint[] not null,
  -- 0..1 — fraction of contributing buildings with a known height.
  confidence  real not null default 0,
  -- 'mapbox' | 'osm'
  source      text not null default 'osm',
  computed_at timestamptz not null default now(),
  constraint venue_sun_horizon_bins check (array_length(horizon, 1) = 72)
);

alter table venue_sun enable row level security;

-- Read-only to signed-in users: horizons are derived public geodata, but there
-- is no reason for a client to ever write one. Only the Edge Function
-- (service_role) populates this table.
drop policy if exists venue_sun_select on venue_sun;
create policy venue_sun_select on venue_sun
  for select to authenticated using (true);

-- Everything a client needs to render the Sun map for an area in one call.
create or replace function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence
  from venues v
  join venue_sun s on s.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m;
$$;

-- Which nearby venues still have no profile, nearest first — the app calls
-- this and warms a handful at a time rather than backfilling the world.
create or replace function venues_missing_sun(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 12
) returns table (venue_id uuid, lat double precision, lon double precision)
language sql stable security definer set search_path = public as $$
  select v.id, v.lat, v.lon
  from venues v
  left join venue_sun s on s.venue_id = v.id
  where s.venue_id is null
    and haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
  order by haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit p_limit;
$$;

grant execute on function venue_sun_map(double precision, double precision, double precision) to authenticated;
grant execute on function venues_missing_sun(double precision, double precision, double precision, integer) to authenticated;

notify pgrst, 'reload schema';
