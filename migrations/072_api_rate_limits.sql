-- 072_api_rate_limits.sql — rate + IP limiting so the API can't be burned.
--
-- WHY: two of our endpoints cost real money or real CPU per call.
--   * `sun-horizon` fetches NINE Mapbox vector tiles per venue and does heavy
--     geometry. A loop hitting it is a bill, not just load.
--   * the public website RPCs (`submit_beer_price_web`, the public map reads)
--     are reachable with the anon key, which is by design public — so the anon
--     key is not a limit on anything.
--
-- The shape: one fixed-window counter table plus a single helper. Fixed
-- windows (not sliding) because they need exactly one upsert per call and no
-- history to prune — a burst can straddle a boundary and get 2x the cap for a
-- moment, which is a fine trade for an abuse guard.
--
-- IP: PostgREST exposes the request headers to SQL, so an RPC can read
-- x-forwarded-for without the client being able to pick its own key. Edge
-- Functions pass their own IP in explicitly.

create table if not exists api_rate_limits (
  bucket       text not null,
  key          text not null,
  window_start timestamptz not null,
  count        integer not null default 0,
  primary key (bucket, key, window_start)
);

alter table api_rate_limits enable row level security;
-- No policies at all: only SECURITY DEFINER functions and service_role touch
-- this. A client must never be able to read or forge counters.

comment on table api_rate_limits is
  'Fixed-window API rate limit counters. Written only by rate_limit_hit().';

-- Count one request against (bucket, key). Returns TRUE when the request is
-- allowed, FALSE when the cap for the current window is already spent.
--
-- The CALLER does not get to choose its own ceiling. p_limit is honoured only up
-- to a per-bucket maximum below. That matters because Edge Functions hold their
-- limits in deployable code, and because sun-horizon's batch mode charges ONE
-- unit for a request that computes up to 120 venues (~1080 Mapbox tile fetches)
-- — the clamp bounds that in the database regardless of what the code asks for.
create or replace function rate_limit_hit(
  p_bucket text,
  p_key    text,
  p_limit  integer,
  p_window interval default '1 hour'
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_start timestamptz;
  v_count integer;
  v_limit integer;
begin
  if p_key is null or p_key = '' then
    -- No key to attribute the call to: treat as one shared bucket rather than
    -- silently letting it through unlimited.
    p_key := 'unknown';
  end if;

  v_limit := least(
    greatest(p_limit, 1),
    case p_bucket
      when 'sun_horizon_user'    then 60
      when 'sun_horizon_ip'      then 120
      when 'sun_horizon_global'  then 4000
      when 'sun_backfill'        then 6
      when 'venue_import'        then 6
      when 'web_read_ip'         then 600
      when 'web_submit_ip'       then 8
      when 'web_submit_ip_burst' then 3
      else 1000
    end
  );

  -- Floor now() onto the window grid.
  v_start := to_timestamp(
    floor(extract(epoch from now()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );

  insert into api_rate_limits (bucket, key, window_start, count)
  values (p_bucket, p_key, v_start, 1)
  on conflict (bucket, key, window_start)
    do update set count = api_rate_limits.count + 1
  returning count into v_count;

  return v_count <= p_limit;
end;
$$;

revoke all on function rate_limit_hit(text, text, integer, interval) from public, anon, authenticated;

-- The caller's IP as PostgREST sees it. x-forwarded-for is a comma-separated
-- chain; the FIRST entry is the client. It is spoofable in general, but here it
-- is set by Supabase's edge proxy, and the fallback keeps a missing header from
-- becoming an unlimited bucket.
create or replace function request_ip() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    nullif(split_part(
      current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1), ''),
    current_setting('request.headers', true)::json ->> 'cf-connecting-ip',
    'unknown'
  );
$$;

revoke all on function request_ip() from public, anon, authenticated;

-- Housekeeping: drop counters for windows nobody will read again.
create or replace function purge_rate_limits() returns void
language sql security definer set search_path = public as $$
  delete from api_rate_limits where window_start < now() - interval '2 days';
$$;

notify pgrst, 'reload schema';
