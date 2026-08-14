-- 102 — freshness window aware of where a price came from.
--
-- The imports carry HONEST report dates from their sources (back to 2023),
-- and venue_beer_prices' flat 90-day window — designed for crowd reports —
-- was silently dropping 2,300 of them, which is why a phone in San
-- Francisco saw bars but no prices. Two clocks now:
--   crowd reports ('app'/'web'):  90 days — the live median stays live;
--   imported baselines (rest):    2 years — a dated-but-real price beats a
--                                 blank map, and the card shows its age.
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
  where (case when bp.source in ('app','web')
              then bp.created_at > now() - interval '90 days'
              else bp.created_at > now() - interval '2 years' end)
    and (p_country is null
         or exists (select 1 from venues v
                    where v.id = bp.venue_id and v.country = p_country))
  group by bp.venue_id, bp.serving
  order by bp.venue_id, bp.serving
  limit greatest(0, p_limit)
  offset greatest(0, p_offset);
$$;
