-- 064_beer_price_currency.sql
--
--  Prices carry their currency (the submitter's device locale — a Tokyo user
--  reports ¥, a Gothenburg user reports kr). Prices are shown and coloured in
--  their own currency; we don't convert. Since a map region is one country,
--  the pins near you are one currency and stay comparable.

alter table beer_prices add column if not exists currency text not null default 'SEK';

-- venue_beer_prices returns the venue+serving's currency (all reports for a
-- bar share one, so the mode is exact).
drop function if exists public.venue_beer_prices();
create function public.venue_beer_prices()
returns table (
  venue_id uuid, serving text, currency text, price numeric, report_count bigint,
  low numeric, high numeric, last_reported timestamptz
) language sql stable security definer set search_path = public as $$
  select bp.venue_id, bp.serving,
         mode() within group (order by bp.currency),
         percentile_cont(0.5) within group (order by bp.price_sek)::numeric(6,2),
         count(*),
         min(bp.price_sek)::numeric(6,2),
         max(bp.price_sek)::numeric(6,2),
         max(bp.created_at)
  from beer_prices bp
  where bp.created_at > now() - interval '90 days'
  group by bp.venue_id, bp.serving;
$$;
grant execute on function public.venue_beer_prices() to authenticated, service_role;

-- Submit gains p_currency; the plausibility band is per-currency (a beer is
-- never ¥50 nor ¥9000).
drop function if exists public.submit_beer_price(
  text, double precision, double precision, text, text, text, numeric, text, text);
create function public.submit_beer_price(
  p_name        text,
  p_lat         double precision,
  p_lon         double precision,
  p_external_id text default null,
  p_city        text default null,
  p_address     text default null,
  p_price       numeric default null,
  p_note        text default null,
  p_serving     text default '40',
  p_currency    text default 'SEK'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid; v_id uuid;
  v_serving  text := coalesce(p_serving, '40');
  v_currency text := upper(coalesce(nullif(p_currency,''), 'SEK'));
  c_min numeric; c_max numeric;
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
  if v_serving not in ('25','33','40','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;

  -- rough plausible band for a single beer, per currency
  c_min := case v_currency when 'SEK' then 10 when 'NOK' then 15 when 'DKK' then 8
                           when 'EUR' then 2 when 'GBP' then 2 when 'USD' then 2
                           when 'JPY' then 150 else 1 end;
  c_max := case v_currency when 'SEK' then 300 when 'NOK' then 400 when 'DKK' then 250
                           when 'EUR' then 30 when 'GBP' then 30 when 'USD' then 30
                           when 'JPY' then 3000 else 100000 end;
  if p_price is null or p_price < c_min or p_price > c_max then raise exception 'implausible_price'; end if;

  select id into v_venue from venues
   where p_external_id is not null and external_id = p_external_id limit 1;
  if v_venue is null then
    select id into v_venue from venues
     where lower(name) = lower(p_name) and abs(lat - p_lat) < 0.001 and abs(lon - p_lon) < 0.001 limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, source, external_id)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id) returning id into v_venue;
  end if;

  delete from beer_prices where venue_id = v_venue and user_id = auth.uid() and serving = v_serving;
  insert into beer_prices (venue_id, user_id, price_sek, serving, currency, note)
  values (v_venue, auth.uid(), p_price, v_serving, v_currency, nullif(p_note,''))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_beer_price(
  text, double precision, double precision, text, text, text, numeric, text, text, text
) to authenticated, service_role;

notify pgrst, 'reload schema';
