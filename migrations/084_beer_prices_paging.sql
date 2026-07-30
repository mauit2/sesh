-- 084_beer_prices_paging.sql — give venue_beer_prices explicit paging.
--
-- WHY NOT JUST PAGE OVER HTTP. PostgREST caps every response at 1000 rows, and
-- this RPC now returns 1180, so the app was silently missing 180 prices — 145 of
-- them 40 cl, the most common serving, which is why 40 cl looked broken while
-- 25/33/50 were fine. The obvious fix is Range-header pagination, the same thing
-- refresh() does for the venues table. IT DOES NOT WORK HERE: this PostgREST
-- ignores Range on POST /rpc/, so asking for rows 1000-1999 returns rows 0-999
-- again. Verified, not assumed — both pages came back with the same first and
-- last venue_id. A client looping on that would spin on page 0 forever and
-- double-count every row it did get, which is worse than the truncation.
--
-- ?limit= and ?offset= query params DO work on RPCs. But relying on those means
-- the correctness of the app's data depends on a transport detail that already
-- surprised us once, so instead the paging becomes part of the function's
-- contract: the caller says what slice it wants and the database obeys.
--
-- THE DEFAULTS MATTER. venue_beer_prices() is also called from inside SQL by the
-- website's RPCs (065, 074), where no row cap applies and truncating would be a
-- silent regression on the website. So the default limit is effectively "all",
-- and only the app passes a page size.

-- Adding defaulted parameters to the existing 0-arg function would create an
-- OVERLOAD, and a no-argument call would then be ambiguous ("function is not
-- unique"). So the old signature has to go first.
drop function if exists public.venue_beer_prices();

create or replace function public.venue_beer_prices(
  p_limit integer default 1000000,
  p_offset integer default 0)
returns table(venue_id uuid, serving text, currency text, price numeric,
              report_count bigint, low numeric, high numeric,
              last_reported timestamp with time zone)
language sql
stable
security definer
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
  group by bp.venue_id, bp.serving
  -- (venue_id, serving) is the group key, so this is a TOTAL order: every row
  -- has a distinct sort key and consecutive pages tile without overlap or gaps.
  -- Paging an unordered aggregate is not safe; Postgres may hand back a
  -- different order per call.
  order by bp.venue_id, bp.serving
  limit greatest(0, p_limit)
  offset greatest(0, p_offset);
$$;

grant execute on function public.venue_beer_prices(integer, integer)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
