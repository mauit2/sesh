-- 063_beer_serving_sizes.sql
--
--  Beer prices become per SERVING SIZE. Five standard servings: 25cl, 33cl,
--  40cl (stor stark), 50cl, and pint. A user reports a price for a specific
--  serving; the map filters by serving and a bar shows all the sizes reported
--  there. Prices aggregate per (venue, serving); one live report per user per
--  venue per serving.

alter table beer_prices rename column kind to serving;
update beer_prices set serving = '40' where serving is null or serving not in ('25','33','40','50','pint');
alter table beer_prices alter column serving set default '40';
alter table beer_prices drop constraint if exists beer_prices_serving_chk;
alter table beer_prices add constraint beer_prices_serving_chk check (serving in ('25','33','40','50','pint'));

-- Aggregate per venue + serving.
drop function if exists public.venue_beer_prices();
create function public.venue_beer_prices()
returns table (
  venue_id uuid, serving text, price numeric, report_count bigint,
  low numeric, high numeric, last_reported timestamptz
) language sql stable security definer set search_path = public as $$
  select bp.venue_id, bp.serving,
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

-- Submit now takes a serving; one live report per user per venue per serving.
drop function if exists public.submit_beer_price(
  text, double precision, double precision, text, text, text, numeric, text);
create function public.submit_beer_price(
  p_name        text,
  p_lat         double precision,
  p_lon         double precision,
  p_external_id text default null,
  p_city        text default null,
  p_address     text default null,
  p_price       numeric default null,
  p_note        text default null,
  p_serving     text default '40'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid; v_id uuid; v_serving text := coalesce(p_serving, '40');
  c_min constant numeric := 15;    -- a 25cl can be cheaper than a stor stark
  c_max constant numeric := 250;
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
  if v_serving not in ('25','33','40','50','pint') then raise exception 'bad_serving'; end if;
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
  insert into beer_prices (venue_id, user_id, price_sek, serving, note)
  values (v_venue, auth.uid(), p_price, v_serving, nullif(p_note,''))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_beer_price(
  text, double precision, double precision, text, text, text, numeric, text, text
) to authenticated, service_role;

notify pgrst, 'reload schema';
