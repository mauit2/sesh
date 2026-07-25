-- 066_web_beer_submissions.sql
--
-- Let anonymous web visitors (seshapp.xyz/map) contribute prices. Web rows
-- have no user_id (they're not signed in); a source column records origin.
-- (Superseded by migration 067, which adds location sanity + a burst cap to
-- submit_beer_price_web — kept here for history.)

alter table beer_prices alter column user_id drop not null;
alter table beer_prices add column if not exists source text not null default 'app';

create or replace function public.submit_beer_price_web(
  p_name text, p_lat double precision, p_lon double precision,
  p_external_id text default null, p_city text default null, p_address text default null,
  p_price numeric default null, p_serving text default '40', p_currency text default 'SEK'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid; v_id uuid;
  v_serving  text := coalesce(p_serving,'40');
  v_currency text := upper(coalesce(nullif(p_currency,''),'SEK'));
  c_min numeric; c_max numeric;
begin
  if coalesce(p_name,'') = '' then raise exception 'name_required'; end if;
  if v_serving not in ('25','33','40','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;
  c_min := case v_currency when 'SEK' then 10 when 'NOK' then 15 when 'DKK' then 8
                           when 'EUR' then 2 when 'GBP' then 2 when 'USD' then 2
                           when 'JPY' then 150 else 1 end;
  c_max := case v_currency when 'SEK' then 300 when 'NOK' then 400 when 'DKK' then 250
                           when 'EUR' then 30 when 'GBP' then 30 when 'USD' then 30
                           when 'JPY' then 3000 else 100000 end;
  if p_price is null or p_price < c_min or p_price > c_max then raise exception 'implausible_price'; end if;

  select id into v_venue from venues where p_external_id is not null and external_id = p_external_id limit 1;
  if v_venue is null then
    select id into v_venue from venues
     where lower(name)=lower(p_name) and abs(lat-p_lat)<0.001 and abs(lon-p_lon)<0.001 limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, source, external_id)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id) returning id into v_venue;
  end if;

  insert into beer_prices (venue_id, user_id, price_sek, serving, currency, note, source)
  values (v_venue, null, p_price, v_serving, v_currency, null, 'web')
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_beer_price_web(
  text, double precision, double precision, text, text, text, numeric, text, text
) to anon, authenticated;

notify pgrst, 'reload schema';
