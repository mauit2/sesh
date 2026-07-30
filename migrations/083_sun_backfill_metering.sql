-- 083_sun_backfill_metering.sql — meter the sun backfill by VENUES, not requests.
--
-- WHY THE OLD LIMIT WAS THE WRONG SHAPE. sun_backfill counted batch REQUESTS and
-- was capped at 6/hour. But a request may carry 1 venue or 120, and it is the
-- venue count that spends money: each venue fetches nine Mapbox vector tiles.
-- So the limit simultaneously (a) blocked a legitimate backfill that needs ~1082
-- venues, and (b) failed to bound the actual spend, since 6 requests x 120
-- venues is ~6,500 tile fetches an hour from anyone holding the public anon key.
-- Metering the thing that costs money fixes both: throughput can go up AND the
-- ceiling becomes meaningful.
--
-- BUDGET SIZING. Mapbox's free vector-tile allowance is 200k requests/month, and
-- one venue is ~9 of them. The daily ceiling of 1500 venues is ~13.5k tiles/day;
-- sustained every day that is ~405k/month, so the DAILY cap alone is not the
-- safety net — it is sized to let a one-off backfill (1082 venues) finish inside
-- a single day. Ongoing demand is far smaller, because a venue is computed once
-- and only new venues trickle in.

-- Ceilings live in one place now, so rate_limit_hit and rate_limit_take cannot
-- drift apart.
create or replace function public.rate_limit_ceiling(p_bucket text)
returns integer
language sql
immutable
as $$
  select case p_bucket
    when 'sun_horizon_user'        then 60
    when 'sun_horizon_ip'          then 120
    when 'sun_horizon_global'      then 4000
    -- Request-count guards. No longer the money-governing limit (the venue
    -- buckets below are), so this can be generous.
    when 'sun_backfill'            then 30
    -- The buckets that actually bound Mapbox spend, in venues.
    when 'sun_horizon_venues_hour' then 400
    when 'sun_horizon_venues_day'  then 1500
    when 'venue_import'            then 6
    when 'web_read_ip'             then 600
    when 'web_submit_ip'           then 8
    when 'web_submit_ip_burst'     then 3
    else 1000
  end;
$$;

create or replace function public.rate_limit_hit(
  p_bucket text, p_key text, p_limit integer,
  p_window interval default '01:00:00'::interval)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_start timestamptz;
  v_count integer;
  v_limit integer;
begin
  if p_key is null or p_key = '' then
    p_key := 'unknown';
  end if;

  -- Server-side ceiling per bucket. A caller may ask for LESS but never more.
  v_limit := least(greatest(p_limit, 1), public.rate_limit_ceiling(p_bucket));

  v_start := to_timestamp(
    floor(extract(epoch from now()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );

  insert into api_rate_limits (bucket, key, window_start, count)
  values (p_bucket, p_key, v_start, 1)
  on conflict (bucket, key, window_start)
    do update set count = api_rate_limits.count + 1
  returning count into v_count;

  return v_count <= v_limit;
end;
$$;

-- Take up to p_n units from a bucket; return how many were actually granted.
--
-- Returning a PARTIAL grant rather than a yes/no is what lets the caller trim a
-- batch to what it can afford instead of being refused outright — a 120-venue
-- request with 30 left in the budget does 30 venues rather than nothing.
create or replace function public.rate_limit_take(
  p_bucket text, p_key text, p_n integer, p_limit integer,
  p_window interval default '01:00:00'::interval)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_start timestamptz;
  v_count integer;
  v_limit integer;
  v_grant integer;
begin
  if p_key is null or p_key = '' then
    p_key := 'unknown';
  end if;
  if p_n is null or p_n <= 0 then
    return 0;
  end if;

  v_limit := least(greatest(p_limit, 1), public.rate_limit_ceiling(p_bucket));

  v_start := to_timestamp(
    floor(extract(epoch from now()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );

  insert into api_rate_limits (bucket, key, window_start, count)
  values (p_bucket, p_key, v_start, 0)
  on conflict (bucket, key, window_start) do nothing;

  -- FOR UPDATE, so two batches running at once cannot both read the same
  -- remaining budget and each spend it. Without the lock the ceiling leaks
  -- under exactly the concurrency a backfill creates.
  select count into v_count
    from api_rate_limits
   where bucket = p_bucket and key = p_key and window_start = v_start
     for update;

  v_grant := greatest(0, least(p_n, v_limit - v_count));
  if v_grant > 0 then
    update api_rate_limits set count = count + v_grant
     where bucket = p_bucket and key = p_key and window_start = v_start;
  end if;
  return v_grant;
end;
$$;

comment on function public.rate_limit_take(text, text, integer, integer, interval) is
  'Atomically take up to p_n units from a rate-limit bucket; returns the number granted (may be 0 or partial).';

-- Pick the venues that still need a horizon, IN PRIORITY ORDER.
--
-- This replaces two client-side selects in the edge function, both of which were
-- silently truncated by PostgREST's 1000-row cap: the venue list (2149 rows) and
-- the already-done list (1067 rows). The function could therefore never see
-- venues past the first 1000, and its "already done" set was short, so it kept
-- reconsidering the same rows. Doing the set difference in SQL has no such cap.
create or replace function public.venues_needing_sun(p_limit integer default 100)
returns table(id uuid, lat double precision, lon double precision)
language sql
stable
security definer
set search_path to 'public'
as $$
  select v.id, v.lat, v.lon
    from venues v
   where v.lat is not null
     and v.lon is not null
     and not exists (select 1 from venue_sun s where s.venue_id = v.id)
   order by
     -- Priced bars first: those are the ones the app promises a sun/shade icon
     -- for, so they are the venues whose absence is actually visible.
     (exists (select 1 from beer_prices b where b.venue_id = v.id)) desc,
     coalesce(v.prominence, 0) desc,
     v.id
   limit greatest(1, least(p_limit, 500));
$$;

-- Only the edge function (service_role) needs these.
revoke all on function public.venues_needing_sun(integer) from public, anon, authenticated;
revoke all on function public.rate_limit_take(text, text, integer, integer, interval)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
