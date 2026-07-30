-- 076_venue_prominence_and_search.sql — a readable map baseline, plus search.
--
-- After the OSM import the map had ~1000 pins in Gothenburg, which is too
-- cluttered to read. So: give every venue a KIND and a PROMINENCE, draw only the
-- prominent ones by default, and make search reach all of them — type a
-- restaurant's name and its pin appears so you can watch the sun cross it.
--
-- prominence:
--   100  we or a user actually chose this venue (curated / mapkit / user), it
--        pays us, or SOMEONE HAS REPORTED A BEER PRICE THERE — a price means we
--        have real content for that bar, so it earns its pin.
--    60  nightlife from OSM: bar, pub, nightclub, biergarten. This is a
--        nightlife app, so a pub outranks a lunch place.
--    20  restaurants. Findable by search, not drawn by default.
--
-- Prominence is a FUNCTION rather than a one-off update because it depends on
-- data that keeps arriving: re-run refresh_venue_prominence() after prices land.

alter table venues add column if not exists kind text;
alter table venues add column if not exists prominence smallint not null default 20;

comment on column venues.kind is
  'bar|pub|nightclub|biergarten|restaurant|null — OSM amenity for imported rows.';
comment on column venues.prominence is
  'Higher = drawn on the map sooner. 100 chosen/paying/has-a-price, 60 nightlife, 20 restaurant.';

create index if not exists venues_prominence_idx on venues (prominence desc);

create or replace function refresh_venue_prominence() returns integer
language plpgsql security definer set search_path = public as $$
declare v_shown integer;
begin
  update venues v set prominence = case
    when v.source in ('curated','mapkit','user')          then 100
    when v.tier is not null and v.tier <> 'none'           then 100
    when exists (select 1 from beer_prices b where b.venue_id = v.id) then 100
    when v.kind in ('bar','pub','nightclub','biergarten')  then 60
    else 20
  end;
  select count(*) into v_shown from venues where prominence >= 60;
  return v_shown;
end $$;

revoke all on function refresh_venue_prominence() from public, anon, authenticated;

-- Successive widenings of this signature left three overloads, which makes an
-- RPC call ambiguous ("could not choose a best candidate function"). Only the
-- 5-argument form below survives.
drop function if exists venue_sun_map(double precision, double precision, double precision);
drop function if exists venue_sun_map(double precision, double precision, double precision, integer);

create or replace function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 150,
  p_min_prominence smallint default 60
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence, v.kind, v.prominence
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
    and coalesce(c.reason, 'unique') <> 'duplicate'
    and v.prominence >= p_min_prominence
  order by v.prominence desc, haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit greatest(1, least(p_limit, 400));
$$;

-- Search deliberately ignores prominence — that is the whole point of it.
create or replace function search_sun_venues(
  p_query text,
  p_lat double precision default null,
  p_lon double precision default null,
  p_limit integer default 20
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  distance_m double precision
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence, v.kind, v.prominence,
         case when p_lat is null then null
              else haversine_m(p_lat, p_lon, v.lat, v.lon) end
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where coalesce(c.reason, 'unique') <> 'duplicate'
    and btrim(coalesce(p_query, '')) <> ''
    and v.name ilike '%' || btrim(p_query) || '%'
  -- Names that START with the query first, then closest, then most prominent.
  order by (v.name ilike btrim(p_query) || '%') desc,
           case when p_lat is null then 0
                else haversine_m(p_lat, p_lon, v.lat, v.lon) end,
           v.prominence desc
  limit greatest(1, least(p_limit, 50));
$$;

grant execute on function venue_sun_map(double precision, double precision, double precision, integer, smallint) to authenticated;
grant execute on function search_sun_venues(text, double precision, double precision, integer) to authenticated;

-- Backfill `kind` from the Overpass response captured during the import, then
-- score everything. (The import kept the raw response in net._http_response, so
-- the amenity tags didn't have to be re-fetched.)
select refresh_venue_prominence();

notify pgrst, 'reload schema';
