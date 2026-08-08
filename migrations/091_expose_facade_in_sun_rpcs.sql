-- 091_expose_facade_in_sun_rpcs.sql — let the client SEE a facade report.
--
-- 090 added the reporting path but neither sun RPC returned facade_bearing or
-- facade_reports, so a correction landed in the database and then vanished: the
-- pin's provenance line only knew about override_horizon ("SET BY HAND"), which
-- is the older by-hand mechanism and is NOT what a user report sets. Someone
-- pointing us the right way would have seen no sign it had worked.
--
-- Adding OUT columns changes a function's row type, which CREATE OR REPLACE
-- refuses ("cannot change return type of existing function"), hence the drops.

drop function if exists public.venue_sun_by_ids(uuid[]);
drop function if exists public.venue_sun_map(double precision, double precision, double precision, integer, smallint);

create function public.venue_sun_by_ids(p_ids uuid[])
returns table(venue_id uuid, name text, lat double precision, lon double precision,
              horizon smallint[], confidence real, kind text, prominence smallint,
              time_zone text, is_override boolean,
              facade_bearing smallint, facade_reports smallint)
language sql
stable
security definer
set search_path to 'public'
as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         s.facade_bearing, s.facade_reports
    from venues v
    join venue_sun s on s.venue_id = v.id
   where v.id = any(p_ids)
   limit 400;
$$;

create function public.venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 80,
  p_min_prominence smallint default 60)
returns table(venue_id uuid, name text, lat double precision, lon double precision,
              horizon smallint[], confidence real, kind text, prominence smallint,
              time_zone text, is_override boolean,
              facade_bearing smallint, facade_reports smallint)
language sql
stable
security definer
set search_path to 'public'
as $$
  with nearby as (
    select v.id, v.name, v.lat, v.lon,
           coalesce(s.override_horizon, s.horizon) as horizon,
           s.confidence, v.kind, v.prominence, v.time_zone,
           (s.override_horizon is not null) as is_override,
           s.facade_bearing, s.facade_reports,
           exists (select 1 from beer_prices b where b.venue_id = v.id) as priced,
           haversine_m(p_lat, p_lon, v.lat, v.lon) as dist
      from venues v
      join venue_sun s on s.venue_id = v.id
      left join venue_canonical c on c.venue_id = v.id
     where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
       and coalesce(c.reason, 'unique') <> 'duplicate'
  )
  select id, name, lat, lon, horizon, confidence, kind, prominence,
         time_zone, is_override, facade_bearing, facade_reports
    from nearby
   where priced or prominence >= p_min_prominence
   order by priced desc, dist
   limit greatest(1, least(p_limit, 400));
$$;

grant execute on function public.venue_sun_by_ids(uuid[]) to anon, authenticated, service_role;
grant execute on function public.venue_sun_map(double precision, double precision, double precision, integer, smallint) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
