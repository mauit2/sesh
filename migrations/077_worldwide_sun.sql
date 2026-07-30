-- 077_worldwide_sun.sql — make "where's the sun" work anywhere on earth.
--
-- The physics was already global: the NOAA solar position in SunMath takes a
-- latitude and longitude and works at any of them, and the horizons come from
-- Mapbox building tiles, which have worldwide coverage (verified against Atlas
-- Bar in Singapore — blocked to 87°, which is correct for Parkview Square's
-- courtyard). Two things were NOT global.
--
-- 1. TIME ZONES. "Today" and "sun till 20:05" were resolved with the DEVICE's
--    calendar. Looking up a Singapore bar from Sweden gave the right 45-minute
--    sun window stamped in Swedish time — 05:30-06:15 instead of 11:30-12:15,
--    a clean six-hour error, plus the wrong day boundary. So the zone is stored
--    per venue and every read path returns it.
--
-- 2. COVERAGE. Search could only return venues that already had a horizon, and
--    we only hold horizons for places someone has looked at. `sun_venue` lets
--    the client fetch one venue's profile straight after creating it from a
--    worldwide Apple Maps search and having its horizon computed on demand.

alter table venues add column if not exists time_zone text;

comment on column venues.time_zone is
  'IANA zone (e.g. Asia/Singapore). Resolves the venue-local day and formats sun times. Null = the client falls back to a longitude estimate until MapKit fills it in.';

-- Everything imported so far is Gothenburg; Atlas Bar was a Singapore test.
update venues set time_zone = 'Europe/Stockholm'
where time_zone is null and lat between 55 and 60 and lon between 10 and 15;
update venues set time_zone = 'Asia/Singapore'
where time_zone is null and lat between -2 and 3 and lon between 102 and 105;

-- Adding an OUT column changes the row type, so these must be dropped first.
drop function if exists venue_sun_map(double precision, double precision, double precision, integer, smallint);
drop function if exists search_sun_venues(text, double precision, double precision, integer);

create function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 80,
  p_min_prominence smallint default 60
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence, v.kind,
         v.prominence, v.time_zone
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
    and coalesce(c.reason, 'unique') <> 'duplicate'
    and v.prominence >= p_min_prominence
  order by v.prominence desc, haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit greatest(1, least(p_limit, 400));
$$;

create function search_sun_venues(
  p_query text,
  p_lat double precision default null,
  p_lon double precision default null,
  p_limit integer default 20
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, distance_m double precision
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence, v.kind,
         v.prominence, v.time_zone,
         case when p_lat is null then null
              else haversine_m(p_lat, p_lon, v.lat, v.lon) end
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where coalesce(c.reason, 'unique') <> 'duplicate'
    and btrim(coalesce(p_query, '')) <> ''
    and v.name ilike '%' || btrim(p_query) || '%'
  order by (v.name ilike btrim(p_query) || '%') desc,
           case when p_lat is null then 0
                else haversine_m(p_lat, p_lon, v.lat, v.lon) end,
           v.prominence desc
  limit greatest(1, least(p_limit, 50));
$$;

-- One venue's profile by id. Called right after a venue is created from a
-- worldwide map search and its horizon has just been computed.
create or replace function sun_venue(p_venue_id uuid)
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence, v.kind,
         v.prominence, v.time_zone
  from venues v
  join venue_sun s on s.venue_id = v.id
  where v.id = p_venue_id;
$$;

-- Let a signed-in client record the zone MapKit reported for a venue it just
-- resolved. Only ever FILLS A BLANK — it never overwrites a known zone, so a
-- client can't relocate a venue's clock.
create or replace function set_venue_time_zone(p_venue_id uuid, p_zone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_zone is null or btrim(p_zone) = '' or length(p_zone) > 64 then return; end if;
  update venues set time_zone = p_zone
  where id = p_venue_id and time_zone is null;
end $$;

grant execute on function venue_sun_map(double precision, double precision, double precision, integer, smallint) to authenticated;
grant execute on function search_sun_venues(text, double precision, double precision, integer) to authenticated;
grant execute on function sun_venue(uuid) to authenticated;
grant execute on function set_venue_time_zone(uuid, text) to authenticated;

notify pgrst, 'reload schema';
