-- 061_beer_prices.sql
--
--  Crowdsourced beer prices on the Deals map. Users report what a "stor stark"
--  (large draught lager — the Swedish reference price) costs at a bar; the map
--  colours each bar green→red by price. v1 canonical unit is stor_stark, kept
--  as a column so sizes/types can be added later without a migration.

create table if not exists beer_prices (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references venues(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  price_sek  numeric(6,2) not null check (price_sek > 0 and price_sek < 1000),
  kind       text not null default 'stor_stark',
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists beer_prices_venue_idx on beer_prices (venue_id, created_at desc);

alter table beer_prices enable row level security;

-- Public crowdsourced data: any signed-in user reads all prices.
drop policy if exists beer_prices_read on beer_prices;
create policy beer_prices_read on beer_prices for select to authenticated using (true);

-- Users may only write their own reports (the RPC is the normal path, but keep
-- table-level policies honest).
drop policy if exists beer_prices_insert on beer_prices;
create policy beer_prices_insert on beer_prices for insert to authenticated with check (user_id = auth.uid());
drop policy if exists beer_prices_delete on beer_prices;
create policy beer_prices_delete on beer_prices for delete to authenticated using (user_id = auth.uid());

-- Representative recent price per venue (median of the last 90 days), plus the
-- spread and how fresh/trusted the data is.
create or replace function public.venue_beer_prices()
returns table (
  venue_id uuid, price numeric, report_count bigint,
  low numeric, high numeric, last_reported timestamptz
) language sql stable security definer set search_path = public as $$
  select bp.venue_id,
         percentile_cont(0.5) within group (order by bp.price_sek)::numeric(6,2),
         count(*),
         min(bp.price_sek)::numeric(6,2),
         max(bp.price_sek)::numeric(6,2),
         max(bp.created_at)
  from beer_prices bp
  where bp.created_at > now() - interval '90 days'
  group by bp.venue_id;
$$;
grant execute on function public.venue_beer_prices() to authenticated, service_role;

-- Submit a price. Finds-or-creates the bar (same match logic as check-in /
-- admin_create_offer) so a MapKit-discovered bar not yet in `venues` works, and
-- replaces this user's previous report for the bar (one live report per user
-- per bar, so nobody can stack the median).
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
declare v_venue uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
  if p_price is null or p_price <= 0 or p_price >= 1000 then raise exception 'bad_price'; end if;

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
