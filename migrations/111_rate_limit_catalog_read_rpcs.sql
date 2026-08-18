-- 111: put a per-caller rate limit on the anon-callable catalog READ RPCs.
-- venue_beer_prices (full-table median aggregation), bars_near, city_index,
-- and country_index were reachable with the public key and uncapped — a
-- single script could call them 100k times/night, burning DB CPU + egress.
-- Wrap each in plpgsql with the same rate_limit_hit() the web write RPCs use,
-- keyed by user when signed in else by IP, 1200/hour (far above any human's
-- cached-catalog usage). Fail closed. Queries preserved verbatim.

create or replace function public.venue_beer_prices(
  p_limit integer default 1000000, p_offset integer default 0, p_country text default null)
returns table(venue_id uuid, serving text, currency text, price numeric,
              report_count bigint, low numeric, high numeric, last_reported timestamptz)
language plpgsql security definer set search_path to 'public'
as $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select bp.venue_id, bp.serving,
           mode() within group (order by bp.currency),
           percentile_cont(0.5) within group (order by bp.price_sek)::numeric(6,2),
           count(*),
           min(bp.price_sek)::numeric(6,2),
           max(bp.price_sek)::numeric(6,2),
           max(bp.created_at)
    from beer_prices bp
    where (case when bp.source in ('app','web')
                then bp.created_at > now() - interval '90 days'
                else bp.created_at > now() - interval '4 years' end)
      and (p_country is null
           or exists (select 1 from venues v
                      where v.id = bp.venue_id and v.country = p_country))
    group by bp.venue_id, bp.serving
    order by bp.venue_id, bp.serving
    limit greatest(0, p_limit)
    offset greatest(0, p_offset);
end $$;

create or replace function public.bars_near(
  p_lat double precision, p_lon double precision, p_km double precision default 12)
returns table(venues bigint, priced bigint, outdoor bigint)
language plpgsql security definer set search_path to 'public'
as $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select count(*),
           count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id)),
           count(*) filter (where v.outdoor_seating = true)
    from venues v
    where abs(v.lat - p_lat) <= p_km / 111.0
      and abs(v.lon - p_lon) <= p_km / (111.0 * greatest(0.2, cos(radians(p_lat))));
end $$;

create or replace function public.city_index(p_country text)
returns table(city text, venues bigint, priced bigint, outdoor bigint,
              min_lat double precision, max_lat double precision,
              min_lon double precision, max_lon double precision)
language plpgsql security definer set search_path to 'public'
as $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
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
end $$;

create or replace function public.country_index()
returns table(country text, venues bigint, priced bigint, outdoor bigint,
              min_lat double precision, max_lat double precision,
              min_lon double precision, max_lon double precision)
language plpgsql security definer set search_path to 'public'
as $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.country, count(*),
           count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id)),
           count(*) filter (where v.outdoor_seating = true),
           min(v.lat), max(v.lat), min(v.lon), max(v.lon)
    from venues v
    where v.country is not null
    group by v.country
    order by count(*) desc;
end $$;
