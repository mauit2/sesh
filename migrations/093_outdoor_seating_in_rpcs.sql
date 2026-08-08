-- 093 — surface venues.outdoor_seating in every RPC that feeds a venue card.
--
-- The column arrived in a manual import (source billigol.se): 1583 true /
-- 1069 false / 0 null at time of writing. Cards show a note only when the
-- value is TRUE — false and unknown both render nothing, so an absent note
-- never claims a bar lacks a terrace.
--
-- Adding a column changes each function's return type, and CREATE OR REPLACE
-- refuses a return-type change — hence DROP + CREATE. Grants die with the
-- function, so each one is re-granted explicitly. Existing clients are safe:
-- both the Swift decoder and the website's JSON handling ignore unknown keys,
-- so shipped builds keep working against the widened rows.

-- ------------------------------------------------------- public_beer_prices
drop function if exists public.public_beer_prices();
create function public.public_beer_prices()
returns table (
  venue_id uuid, venue_name text,
  lat double precision, lon double precision,
  serving text, currency text, price numeric, report_count bigint,
  outdoor boolean
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.id, v.name, v.lat, v.lon, b.serving, b.currency, b.price, b.report_count,
           v.outdoor_seating
    from venue_beer_prices() b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where coalesce(c.reason, 'unique') <> 'duplicate';
end $$;
revoke all on function public.public_beer_prices() from public;
grant execute on function public.public_beer_prices() to anon, authenticated;

-- --------------------------------------------------------- venue_sun_by_ids
drop function if exists public.venue_sun_by_ids(uuid[]);
create function public.venue_sun_by_ids(p_ids uuid[])
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean,
  facade_bearing smallint, facade_reports smallint,
  outdoor_seating boolean
)
language sql
stable security definer
set search_path to 'public'
as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         s.facade_bearing, s.facade_reports,
         v.outdoor_seating
    from venues v
    join venue_sun s on s.venue_id = v.id
   where v.id = any(p_ids)
   limit 400;
$$;
revoke all on function public.venue_sun_by_ids(uuid[]) from public;
grant execute on function public.venue_sun_by_ids(uuid[]) to anon, authenticated;

-- ------------------------------------------------------------ venue_sun_map
drop function if exists public.venue_sun_map(double precision, double precision, double precision, integer, smallint);
create function public.venue_sun_map(
  p_lat double precision, p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 80,
  p_min_prominence smallint default 60
)
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean,
  facade_bearing smallint, facade_reports smallint,
  outdoor_seating boolean
)
language sql
stable security definer
set search_path to 'public'
as $$
  with nearby as (
    select v.id, v.name, v.lat, v.lon,
           coalesce(s.override_horizon, s.horizon) as horizon,
           s.confidence, v.kind, v.prominence, v.time_zone,
           (s.override_horizon is not null) as is_override,
           s.facade_bearing, s.facade_reports,
           v.outdoor_seating,
           exists (select 1 from beer_prices b where b.venue_id = v.id) as priced,
           haversine_m(p_lat, p_lon, v.lat, v.lon) as dist
      from venues v
      join venue_sun s on s.venue_id = v.id
      left join venue_canonical c on c.venue_id = v.id
     where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
       and coalesce(c.reason, 'unique') <> 'duplicate'
  )
  select id, name, lat, lon, horizon, confidence, kind, prominence,
         time_zone, is_override, facade_bearing, facade_reports, outdoor_seating
    from nearby
   where priced or prominence >= p_min_prominence
   order by priced desc, dist
   limit greatest(1, least(p_limit, 400));
$$;
revoke all on function public.venue_sun_map(double precision, double precision, double precision, integer, smallint) from public;
grant execute on function public.venue_sun_map(double precision, double precision, double precision, integer, smallint) to anon, authenticated;

-- ---------------------------------------------------------------- sun_venue
drop function if exists public.sun_venue(uuid);
create function public.sun_venue(p_venue_id uuid)
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean,
  outdoor_seating boolean
)
language sql
stable security definer
set search_path to 'public'
as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         v.outdoor_seating
  from venues v
  join venue_sun s on s.venue_id = v.id
  where v.id = p_venue_id;
$$;
revoke all on function public.sun_venue(uuid) from public;
grant execute on function public.sun_venue(uuid) to anon, authenticated;

-- -------------------------------------------------------- search_sun_venues
drop function if exists public.search_sun_venues(text, double precision, double precision, integer);
create function public.search_sun_venues(
  p_query text,
  p_lat double precision default null,
  p_lon double precision default null,
  p_limit integer default 20
)
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean, distance_m double precision,
  outdoor_seating boolean
)
language sql
stable security definer
set search_path to 'public'
as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         case when p_lat is null then null
              else haversine_m(p_lat, p_lon, v.lat, v.lon) end,
         v.outdoor_seating
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
revoke all on function public.search_sun_venues(text, double precision, double precision, integer) from public;
grant execute on function public.search_sun_venues(text, double precision, double precision, integer) to anon, authenticated;
