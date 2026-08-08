-- 095 — two fixes feeding the website.
--
-- 1) MISFILED CITIES. Nine priced venues carry a city whose actual centre is
--    tens of km away (a Kungsbacka cluster imported as "Varberg", one bar
--    91 km from the Göteborg it claims). The blog groups by venues.city, so
--    these bars appeared in the wrong city's tables and medians — the
--    "discrepancies" a reader can actually see. Reassign each outlier to the
--    city whose venue-median coordinate is nearest, or NULL when nothing is
--    within 20 km: an unfiled bar stays on the map but off city pages, which
--    is the honest state.
--
--    City reference points are the median lat/lon of every venue claiming the
--    city. Medians are robust here: the overwhelming majority of rows are
--    correctly filed, so a handful of outliers can't drag the reference.
--
-- 2) WEB OUTDOOR REPORTS. The app's report_outdoor_seating (094) requires
--    auth.uid(); the website is anonymous. Same contract, IP-limited like the
--    other web write (submit_beer_price_web): reports can only SET the flag,
--    never clear it, so one prank tap can't delist an import-verified terrace.

-- ---------------------------------------------------------- 1. city refile
with refs as (
  select city,
         percentile_cont(0.5) within group (order by lat) mlat,
         percentile_cont(0.5) within group (order by lon) mlon
  from venues where city is not null
  group by city
  having count(*) >= 5          -- a "city" with 2 venues is not a reference
),
misfiled as (
  select v.id
  from venues v join refs r on r.city = v.city
  where haversine_m(v.lat, v.lon, r.mlat, r.mlon) > 25000
),
best as (
  select m.id,
         (select r2.city from refs r2
           order by haversine_m(v.lat, v.lon, r2.mlat, r2.mlon)
           limit 1) as nearest_city,
         (select min(haversine_m(v.lat, v.lon, r2.mlat, r2.mlon)) from refs r2) as nearest_m
  from misfiled m join venues v on v.id = m.id
)
update venues v
   set city = case when b.nearest_m <= 20000 then b.nearest_city else null end
  from best b
 where v.id = b.id;

-- ------------------------------------------------- 2. web outdoor reporting
create or replace function public.report_outdoor_seating_web(p_venue uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not rate_limit_hit('outdoor_report_web', request_ip(), 20, '1 hour') then
    raise exception 'rate_limited';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;

  update venues
     set outdoor_seating            = true,
         outdoor_seating_source     = 'web',
         outdoor_seating_updated_at = now()
   where id = p_venue
     and outdoor_seating is distinct from true;
end $$;

revoke all on function public.report_outdoor_seating_web(uuid) from public;
grant execute on function public.report_outdoor_seating_web(uuid) to anon, authenticated;
