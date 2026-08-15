-- 103 — cities inside the country browser, and a coordinate probe.
--
-- city_index: a country's cities ranked by how much USEFUL data they hold
-- (priced bars + terraces first, raw venue count as the tiebreak), with
-- per-city bounds so the client can frame the city. City strings carry
-- suffixes ("Milan, Italy", "Hoboken, NJ") — display trimming is the
-- client's job; grouping here is exact-string, which is how the imports
-- are keyed.
--
-- bars_near: "is there anything AT these coordinates" for the worldwide
-- city search — the client geocodes any city on device, then asks this
-- how populated it is. Box math, not haversine: at city radii the error
-- is irrelevant and the venues(lat,lon) scan stays cheap.

create or replace function public.city_index(p_country text)
returns table (
  city text, venues bigint, priced bigint, outdoor bigint,
  min_lat double precision, max_lat double precision,
  min_lon double precision, max_lon double precision
)
language sql
stable security definer
set search_path to 'public'
as $$
  select v.city, count(*),
         count(*) filter (where exists
           (select 1 from beer_prices bp where bp.venue_id = v.id)),
         count(*) filter (where v.outdoor_seating = true),
         min(v.lat), max(v.lat), min(v.lon), max(v.lon)
  from venues v
  where v.country = upper(p_country) and v.city is not null
  group by v.city
  order by (count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id))
            + count(*) filter (where v.outdoor_seating = true)) desc,
           count(*) desc
  limit 15;
$$;
revoke all on function public.city_index(text) from public;
grant execute on function public.city_index(text) to authenticated, anon;

create or replace function public.bars_near(
  p_lat double precision, p_lon double precision, p_km double precision default 12)
returns table (venues bigint, priced bigint, outdoor bigint)
language sql
stable security definer
set search_path to 'public'
as $$
  select count(*),
         count(*) filter (where exists
           (select 1 from beer_prices bp where bp.venue_id = v.id)),
         count(*) filter (where v.outdoor_seating = true)
  from venues v
  where abs(v.lat - p_lat) <= p_km / 111.0
    and abs(v.lon - p_lon) <= p_km / (111.0 * greatest(0.2, cos(radians(p_lat))));
$$;
revoke all on function public.bars_near(double precision, double precision, double precision) from public;
grant execute on function public.bars_near(double precision, double precision, double precision) to authenticated, anon;
