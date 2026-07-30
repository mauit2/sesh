-- 085_sun_budget_atomic.sql — reserve the hour and day budgets in ONE step.
--
-- WHAT WENT WRONG IN 083. The edge function took from the daily bucket first and
-- the hourly bucket second, on the theory that if the hour granted less, the day
-- was left slightly over-charged in the "safe" direction. That reasoning was
-- wrong in practice. Once the hourly budget is spent, EVERY retry still charges
-- the day bucket its full request before the hour refuses it — so a client
-- looping with a 60-second backoff burns the daily allowance without doing any
-- work. Observed directly: 788 units charged for ~468 venues actually computed,
-- and climbing by 60 per refused round.
--
-- Ordering the takes the other way round only moves the leak. The fix is to stop
-- taking from two buckets in two steps: reserve against both under one lock, and
-- grant the minimum. A refusal then costs nothing, which is the property a
-- retrying caller needs.

create or replace function public.sun_venue_budget_take(p_n integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  h_start timestamptz;
  d_start timestamptz;
  h_count integer;
  d_count integer;
  h_limit integer := public.rate_limit_ceiling('sun_horizon_venues_hour');
  d_limit integer := public.rate_limit_ceiling('sun_horizon_venues_day');
  v_grant integer;
begin
  if p_n is null or p_n <= 0 then
    return 0;
  end if;

  h_start := to_timestamp(floor(extract(epoch from now()) / 3600) * 3600);
  d_start := to_timestamp(floor(extract(epoch from now()) / 86400) * 86400);

  insert into api_rate_limits (bucket, key, window_start, count)
  values ('sun_horizon_venues_hour', 'all', h_start, 0),
         ('sun_horizon_venues_day',  'all', d_start, 0)
  on conflict (bucket, key, window_start) do nothing;

  -- Lock both rows, always hour before day. A FIXED order matters: two callers
  -- locking them in opposite orders would deadlock.
  select count into h_count from api_rate_limits
   where bucket = 'sun_horizon_venues_hour' and key = 'all' and window_start = h_start
     for update;
  select count into d_count from api_rate_limits
   where bucket = 'sun_horizon_venues_day' and key = 'all' and window_start = d_start
     for update;

  -- Grant the minimum, then charge BOTH buckets exactly that. Nothing is spent
  -- when the grant is zero.
  v_grant := greatest(0, least(p_n, h_limit - h_count, d_limit - d_count));
  if v_grant > 0 then
    update api_rate_limits set count = count + v_grant
     where bucket = 'sun_horizon_venues_hour' and key = 'all' and window_start = h_start;
    update api_rate_limits set count = count + v_grant
     where bucket = 'sun_horizon_venues_day' and key = 'all' and window_start = d_start;
  end if;
  return v_grant;
end;
$$;

comment on function public.sun_venue_budget_take(integer) is
  'Atomically reserve up to p_n venue-units against BOTH the hourly and daily sun budgets; returns the number granted. A refused call charges nothing.';

revoke all on function public.sun_venue_budget_take(integer) from public, anon, authenticated;

-- Correct the ledger the two-step version inflated: set it to the venues this
-- metering has actually paid for, which is those computed since the venue
-- budgets started existing (the v7 deploy). Earlier work today ran under the
-- old request-based limits, and charging it here would just block the rest of a
-- legitimate one-off backfill against a budget that was not measuring it. The
-- forward-looking ceiling is unchanged.
update api_rate_limits
   set count = (select count(*) from venue_sun
                 where computed_at >= to_timestamp(1785440794))
 where bucket = 'sun_horizon_venues_day'
   and key = 'all'
   and window_start = to_timestamp(floor(extract(epoch from now()) / 86400) * 86400);

notify pgrst, 'reload schema';
