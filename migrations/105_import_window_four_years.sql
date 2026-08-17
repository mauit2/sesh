-- 105: widen the imported-price window from 2 to 4 years. Migration 102's
-- two-clock design (crowd 90 days, imports 2 years) was meant to keep
-- honestly-dated scrapes visible — but scrapes dated 2023 have now aged past
-- 2 years, silently hiding ~250 of the UK's 727 priced bars from the map and
-- the blog while country_index still counted them. Four years keeps every
-- import currently in the catalog visible; crowd reports stay at 90 days.
create or replace function public.venue_beer_prices(
  p_limit integer default 1000000,
  p_offset integer default 0,
  p_country text default null
)
returns table(venue_id uuid, serving text, currency text, price numeric,
              report_count bigint, low numeric, high numeric,
              last_reported timestamp with time zone)
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
$$;
