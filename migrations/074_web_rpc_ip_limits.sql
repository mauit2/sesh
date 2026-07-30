-- 074_web_rpc_ip_limits.sql — per-IP caps on everything the website can reach.
--
-- WHY: the anon/publishable key is public by design (it ships in the site's
-- JavaScript), so it is not a limit on anything. These caps are. Reads get a
-- generous ceiling — a real visitor makes a handful of calls per page load, and
-- users behind shared NAT must not be locked out — while the write path gets a
-- strict one on top of the global burst cap it already had.
--
-- Both read functions become VOLATILE (they were STABLE) because counting a
-- request writes a row. Return columns are unchanged, so PostgREST and the site
-- keep working. They also now filter out non-canonical duplicate venues, so the
-- website stops showing the same bar twice (see 073_venue_canonical.sql).
--
-- Depends on rate_limit_hit() and request_ip() from 072_api_rate_limits.sql.

create or replace function public_beer_prices()
returns table (venue_id uuid, venue_name text, lat double precision,
               lon double precision, serving text, currency text,
               price numeric, report_count bigint)
language plpgsql volatile security definer set search_path = public as $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.id, v.name, v.lat, v.lon, b.serving, b.currency, b.price, b.report_count
    from venue_beer_prices() b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where coalesce(c.reason, 'unique') <> 'duplicate';
end $$;

create or replace function public_deals()
returns table (venue_id uuid, venue_name text, lat double precision,
               lon double precision, title text, description text, kind text,
               placement text, image_url text, active_days integer[])
language plpgsql volatile security definer set search_path = public as $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select o.venue_id, v.name, v.lat, v.lon,
           o.title, o.description, o.kind, o.placement, o.image_url, o.active_days
    from venue_offers o
    join venues v on v.id = o.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where o.is_active and o.approved
      and coalesce(c.reason, 'unique') <> 'duplicate'
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at   is null or o.ends_at   >  now());
end $$;

-- Unchanged from 067 apart from the two per-IP gates at the top.
create or replace function submit_beer_price_web(
  p_name text, p_lat double precision, p_lon double precision,
  p_external_id text default null, p_city text default null,
  p_address text default null, p_price numeric default null,
  p_serving text default '40', p_currency text default 'SEK')
returns uuid
language plpgsql security definer set search_path = public as $function$
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
  if v_serving not in ('25','33','40','50','pint') then raise exception 'bad_serving'; end if;
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

notify pgrst, 'reload schema';
