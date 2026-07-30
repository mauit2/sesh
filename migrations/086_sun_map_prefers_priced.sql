-- 086_sun_map_prefers_priced.sql — the Sun map shows the bars you can price.
--
-- WHAT WAS WRONG. venue_sun_map picked purely on `prominence >= 60`, ordered by
-- prominence. Prominence is a rough editorial score, so the Sun map showed a
-- scattering of "notable" venues that had nothing to do with the bars the Beer
-- map shows — the same city rendered two unrelated sets of pins, and the Sun one
-- looked arbitrary.
--
-- It also quietly broke a promise made earlier: a bar with a beer price is
-- supposed to always carry a sun/shade icon. A priced bar scoring under 60
-- never appeared at all.
--
-- NOW: every bar with a reported price comes first, nearest first, and prominent
-- venues only fill whatever room is left under p_limit. In a city with more
-- priced bars than the limit, the Sun map and the Beer map draw the same bars.
--
-- Ordering by distance rather than prominence within the priced set is
-- deliberate: this map answers "is there sun where I am", so the nearest bars
-- are the useful ones, and prominence has no bearing on that.

create or replace function public.venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 80,
  p_min_prominence smallint default 60)
returns table(venue_id uuid, name text, lat double precision, lon double precision,
              horizon smallint[], confidence real, kind text, prominence smallint,
              time_zone text, is_override boolean)
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
           exists (select 1 from beer_prices b where b.venue_id = v.id) as priced,
           haversine_m(p_lat, p_lon, v.lat, v.lon) as dist
      from venues v
      join venue_sun s on s.venue_id = v.id
      left join venue_canonical c on c.venue_id = v.id
     where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
       and coalesce(c.reason, 'unique') <> 'duplicate'
  )
  select id, name, lat, lon, horizon, confidence, kind, prominence,
         time_zone, is_override
    from nearby
   -- A priced bar is always eligible, whatever its prominence. That is the
   -- whole point: the icon promise applies to priced bars, not popular ones.
   where priced or prominence >= p_min_prominence
   order by priced desc, dist
   limit greatest(1, least(p_limit, 400));
$$;

-- The per-venue EXISTS runs once per candidate in the radius, so make sure the
-- lookup it does is indexed.
create index if not exists beer_prices_venue_id_idx on beer_prices (venue_id);

notify pgrst, 'reload schema';
