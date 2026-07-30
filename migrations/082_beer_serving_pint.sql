-- 082_beer_serving_pint.sql — recognise pints, and make the price RPC pageable.
--
-- TWO UNRELATED BUGS, ONE MIGRATION, because both are about beer_prices rows
-- being invisible in the app.
--
-- (1) PINTS. The app knows five servings: 25, 33, 40, 50, pint. An imperial pint
--     is 568 ml, and bars report that as 56 or 57 (and occasionally 55 or 59,
--     depending on whether they round the glass or the pour). Those rows matched
--     no filter, so the price existed in the database and on the website but the
--     bar had no dot on the map. Normalise the 55-59 band onto 'pint'.
--
--     THE BAND STOPS AT 59 ON PURPOSE. 60, 62 and 66 cl are genuinely different
--     glasses, not a pint measured sloppily — 66 cl is two thirds of a litre.
--     Folding them in would misstate their price per volume by up to 16%, which
--     is worse than leaving them out, because the map's colours mean "cheap or
--     pricey FOR THIS SERVING". Same reasoning leaves 45/42/36/35/30/20 alone.
--     That is 32 rows across 30 venues still unmapped; they need either their
--     own servings or a price-per-litre comparison, which is a product decision,
--     not a data fix.
--
-- (2) PAGINATION. venue_beer_prices() had no ORDER BY. That was harmless while
--     the client fetched it in one go, but PostgREST caps every response at 1000
--     rows — including RPC results — and the table just passed that, silently
--     dropping 180 of 1180 prices. The client now pages with Range headers, and
--     paging an unordered aggregate is not safe: Postgres may hand back rows in
--     a different order per page, so rows can repeat or vanish. Give it a total
--     order so the pages actually tile.

-- Keep what was reported. Normalising is lossy, and if the pint band ever turns
-- out to be wrong we need the original to undo it.
alter table beer_prices add column if not exists serving_raw text;

comment on column beer_prices.serving_raw is
  'Serving exactly as reported, before normalisation (see 082). Null = never normalised.';

update beer_prices set serving_raw = serving where serving_raw is null;

-- 568 ml +/- 13 ml. Anything outside this is a different glass, not a pint.
create or replace function public.normalize_beer_serving(s text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
    when s ~ '^[0-9]+$' and s::int between 55 and 59 then 'pint'
    else s
  end;
$$;

comment on function public.normalize_beer_serving(text) is
  'Maps a reported serving onto one the app can filter. Currently only the imperial-pint band (55-59 cl) -> ''pint''.';

update beer_prices
   set serving = public.normalize_beer_serving(serving)
 where public.normalize_beer_serving(serving) is distinct from serving;

-- Without this, the next bar that reports a 56 cl pint reintroduces the bug.
create or replace function public.beer_prices_normalize_serving()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.serving_raw is null then
    new.serving_raw := new.serving;
  end if;
  new.serving := public.normalize_beer_serving(new.serving);
  return new;
end;
$$;

drop trigger if exists trg_beer_prices_normalize_serving on beer_prices;
create trigger trg_beer_prices_normalize_serving
  before insert or update of serving on beer_prices
  for each row execute function public.beer_prices_normalize_serving();

-- (2) Total order, so Range-header pagination tiles cleanly.
create or replace function public.venue_beer_prices()
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
  -- has a distinct sort key and the pages cannot overlap or leave gaps.
  order by bp.venue_id, bp.serving;
$$;

notify pgrst, 'reload schema';
