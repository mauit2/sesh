-- 100 — first-class 16 oz serving ("47.3", its true centilitres).
--
-- The US import put a third of its prices under the 50 cl chip because the
-- app had no American size. The serving column already allows any numeric
-- cl (the 063 whitelist constraint was relaxed for the imports), so the
-- canonical representation is the exact pour: '47.3'. The app renders it
-- as "16 oz" and shows it by default when the map is over the US/Canada.
--
-- Two submit paths still whitelisted the old five sizes — extend both.
-- Then move every imported row whose true pour was 16 oz (serving_raw
-- '47.3', parked under '50') onto the new serving.

create or replace function public.submit_beer_price(p_name text, p_lat double precision, p_lon double precision, p_external_id text default null::text, p_city text default null::text, p_address text default null::text, p_price numeric default null::numeric, p_note text default null::text, p_serving text default '40'::text, p_currency text default 'SEK'::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_venue uuid; v_id uuid;
  v_serving  text := coalesce(p_serving, '40');
  v_currency text := upper(coalesce(nullif(p_currency,''), 'SEK'));
  c_min numeric; c_max numeric;
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
  if v_serving not in ('25','33','40','47.3','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;

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
end $function$;

create or replace function public.submit_beer_price_web(p_name text, p_lat double precision, p_lon double precision, p_external_id text default null::text, p_city text default null::text, p_address text default null::text, p_price numeric default null::numeric, p_serving text default '40'::text, p_currency text default 'SEK'::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_venue uuid; v_id uuid; v_recent int;
  v_serving  text := coalesce(p_serving,'40');
  v_currency text := upper(coalesce(nullif(p_currency,''),'SEK'));
  v_ip text := request_ip();
  c_min numeric; c_max numeric;
begin
  -- Per-IP caps first: cheapest possible rejection for an abusive client.
  if not rate_limit_hit('web_submit_ip_burst', v_ip, 3, '1 minute') then
    raise exception 'rate_limited';
  end if;
  if not rate_limit_hit('web_submit_ip', v_ip, 8, '1 hour') then
    raise exception 'rate_limited';
  end if;

  if coalesce(p_name,'') = '' then raise exception 'name_required'; end if;
  if v_serving not in ('25','33','40','47.3','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;
  if p_lat is null or p_lon is null or abs(p_lat) > 90 or abs(p_lon) > 180
     or (abs(p_lat) < 0.01 and abs(p_lon) < 0.01) then raise exception 'bad_location'; end if;
  select count(*) into v_recent from beer_prices
    where source = 'web' and created_at > now() - interval '1 minute';
  if v_recent >= 30 then raise exception 'rate_limited'; end if;

  c_min := case v_currency when 'SEK' then 10 when 'NOK' then 15 when 'DKK' then 8
                           when 'EUR' then 2 when 'GBP' then 2 when 'USD' then 2
                           when 'JPY' then 150 else 1 end;
  c_max := case v_currency when 'SEK' then 300 when 'NOK' then 400 when 'DKK' then 250
                           when 'EUR' then 30 when 'GBP' then 30 when 'USD' then 30
                           when 'JPY' then 3000 else 100000 end;
  if p_price is null or p_price < c_min or p_price > c_max then raise exception 'implausible_price'; end if;

  select id into v_venue from venues where p_external_id is not null and external_id = p_external_id limit 1;
  if v_venue is null then
    select id into v_venue from venues where lower(name)=lower(p_name)
      and abs(lat-p_lat)<0.001 and abs(lon-p_lon)<0.001 limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, source, external_id)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id) returning id into v_venue;
  end if;

  insert into beer_prices (venue_id, user_id, price_sek, serving, currency, note, source)
  values (v_venue, null, p_price, v_serving, v_currency, null, 'web')
  returning id into v_id;
  return v_id;
end $function$;

-- Imported 16 oz pours move from the 50 cl approximation to their true size.
update beer_prices set serving = '47.3' where serving_raw = '47.3' and serving = '50';
