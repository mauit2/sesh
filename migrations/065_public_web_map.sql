-- 065_public_web_map.sql
--
-- Read-only, anonymous-accessible endpoints for the public web map at
-- seshapp.xyz/map. SECURITY DEFINER so they read past RLS, but expose only the
-- handful of fields the map shows (never user ids or raw tables).

create or replace function public.public_beer_prices()
returns table (
  venue_id uuid, venue_name text, lat double precision, lon double precision,
  serving text, currency text, price numeric, report_count bigint
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, b.serving, b.currency, b.price, b.report_count
  from venue_beer_prices() b
  join venues v on v.id = b.venue_id;
$$;
grant execute on function public.public_beer_prices() to anon, authenticated;

create or replace function public.public_deals()
returns table (
  venue_id uuid, venue_name text, lat double precision, lon double precision,
  title text, description text, kind text, placement text,
  image_url text, active_days int[]
) language sql stable security definer set search_path = public as $$
  select o.venue_id, v.name, v.lat, v.lon,
         o.title, o.description, o.kind, o.placement, o.image_url, o.active_days
  from venue_offers o
  join venues v on v.id = o.venue_id
  where o.is_active and o.approved
    and (o.starts_at is null or o.starts_at <= now())
    and (o.ends_at   is null or o.ends_at   >  now());
$$;
grant execute on function public.public_deals() to anon, authenticated;

notify pgrst, 'reload schema';
