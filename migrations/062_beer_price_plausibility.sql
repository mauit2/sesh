-- 062_beer_price_plausibility.sql
--
--  Quality guard for crowdsourced prices: reject implausible "stor stark"
--  submissions (a 10 kr or 500 kr beer isn't real). Combined with the
--  median aggregate + one-live-report-per-user-per-bar, this keeps the map
--  honest. Band is enforced in the RPC (not a CHECK) so it's tunable.

create or replace function public.submit_beer_price(
  p_name        text,
  p_lat         double precision,
  p_lon         double precision,
  p_external_id text default null,
  p_city        text default null,
  p_address     text default null,
  p_price       numeric default null,
  p_note        text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid; v_id uuid;
  c_min constant numeric := 25;    -- a real stor stark is never this cheap
  c_max constant numeric := 200;   -- …nor this dear
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
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

  delete from beer_prices where venue_id = v_venue and user_id = auth.uid();
  insert into beer_prices (venue_id, user_id, price_sek, note)
  values (v_venue, auth.uid(), p_price, nullif(p_note,''))
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.submit_beer_price(
  text, double precision, double precision, text, text, text, numeric, text
) to authenticated, service_role;

notify pgrst, 'reload schema';
