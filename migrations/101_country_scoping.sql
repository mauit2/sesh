-- 101 — country-scoped catalog.
--
-- The catalog crossed 3600 venues across 12 countries today, and every
-- client was still pulling ALL of it on a full sync. From here the app
-- loads one country at a time: venues carry an ISO-3166 alpha-2 country,
-- a countries index answers "what exists where" (counts + bounds for the
-- fly-to), and the price feed filters server-side.
--
-- Backfill: explicit city suffixes first ("Milan, Italy", "Hoboken, NJ"),
-- then the Swedish coordinate box for the bare-name legacy rows. Anything
-- still null after this is handled row-by-row (should be a handful of
-- MapKit-created strays).

alter table venues add column if not exists country text;
create index if not exists idx_venues_country on venues (country);

update venues v set country = m.iso
from (values
  ('NY','US'), ('NJ','US'), ('United States','US'),
  ('France','FR'), ('Italy','IT'), ('Spain','ES'), ('Portugal','PT'),
  ('Belgium','BE'), ('Germany','DE'), ('Switzerland','CH'),
  ('Netherlands','NL'), ('Canada','CA'), ('Brazil','BR'), ('Sweden','SE')
) m(suffix, iso)
where v.country is null
  and trim(substring(v.city from ',([^,]*)$')) = m.suffix;

update venues set country = 'SE'
where country is null
  and lat between 55.0 and 69.2 and lon between 10.5 and 24.2;

-- ---------------------------------------------------------------- index
-- One row per country: how much lives there, and where "there" is.
create or replace function public.country_index()
returns table (
  country text, venues bigint, priced bigint, outdoor bigint,
  min_lat double precision, max_lat double precision,
  min_lon double precision, max_lon double precision
)
language sql
stable security definer
set search_path to 'public'
as $$
  select v.country, count(*),
         count(*) filter (where exists
           (select 1 from beer_prices bp where bp.venue_id = v.id)),
         count(*) filter (where v.outdoor_seating = true),
         min(v.lat), max(v.lat), min(v.lon), max(v.lon)
  from venues v
  where v.country is not null
  group by v.country
  order by count(*) desc;
$$;
revoke all on function public.country_index() from public;
grant execute on function public.country_index() to authenticated, anon;

-- ------------------------------------------------------- price feed scope
drop function if exists public.venue_beer_prices(integer, integer);
create or replace function public.venue_beer_prices(
  p_limit integer default 1000000, p_offset integer default 0,
  p_country text default null)
returns table (venue_id uuid, serving text, currency text, price numeric,
               report_count bigint, low numeric, high numeric,
               last_reported timestamptz)
language sql
stable security definer
set search_path to 'public'
as $$
  select bp.venue_id, bp.serving,
         mode() within group (order by bp.currency),
         percentile_cont(0.5) within group (order by bp.price_sek)::numeric(6,2),
         count(*),
         min(bp.price_sek)::numeric(6,2),
         max(bp.price_sek)::numeric(6,2),
         max(bp.created_at)
  from beer_prices bp
  where bp.created_at > now() - interval '90 days'
    and (p_country is null
         or exists (select 1 from venues v
                    where v.id = bp.venue_id and v.country = p_country))
  group by bp.venue_id, bp.serving
  order by bp.venue_id, bp.serving
  limit greatest(0, p_limit)
  offset greatest(0, p_offset);
$$;
revoke all on function public.venue_beer_prices(integer, integer, text) from public;
grant execute on function public.venue_beer_prices(integer, integer, text) to authenticated, anon;
