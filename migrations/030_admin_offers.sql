-- 030_admin_offers.sql
--
-- Lets the owner/admins manage venue specials from inside the app instead of
-- hand-writing SQL each time. Three SECURITY DEFINER RPCs, each gated on
-- app_admins membership (same pattern as the barcode-catalog admin RPCs):
--
--   • admin_create_offer — finds/creates the venue (matched on the MapKit
--     external_id when present) and inserts the offer, approved + active.
--   • admin_delete_offer — removes an offer.
--   • admin_list_offers — every offer + its venue, for the management list.
--
-- Clients still can't write venue_offers / venues directly (no RLS write
-- policies); these functions are the only door, and only for admins.

create or replace function admin_create_offer(
  p_name        text,
  p_address     text,
  p_city        text,
  p_lat         double precision,
  p_lon         double precision,
  p_external_id text,
  p_kind        text,
  p_title       text,
  p_description text,
  p_fine_print  text,
  p_redeem      text,
  p_code        text,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_active_days int[],
  p_start_minute int,
  p_end_minute  int
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_venue uuid; v_offer uuid;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'title required';
  end if;

  -- Find the venue by its MapKit id first; otherwise create a curated one.
  if coalesce(p_external_id, '') <> '' then
    select id into v_venue from venues where external_id = p_external_id limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, is_featured, source, external_id)
    values (p_name, nullif(p_address, ''), nullif(p_city, ''), p_lat, p_lon,
            true, 'curated', nullif(p_external_id, ''))
    returning id into v_venue;
  else
    -- Keep its coordinates fresh + mark it featured.
    update venues set lat = p_lat, lon = p_lon, is_featured = true where id = v_venue;
  end if;

  insert into venue_offers (
    venue_id, kind, title, description, fine_print, redeem, code,
    starts_at, ends_at, active_days, start_minute, end_minute, is_active, approved
  ) values (
    v_venue,
    coalesce(nullif(p_kind, ''), 'price'),
    btrim(p_title),
    nullif(btrim(coalesce(p_description, '')), ''),
    nullif(btrim(coalesce(p_fine_print, '')), ''),
    coalesce(nullif(p_redeem, ''), 'show'),
    nullif(p_code, ''),
    coalesce(p_starts_at, now()),
    p_ends_at,
    p_active_days,
    p_start_minute,
    p_end_minute,
    true, true
  ) returning id into v_offer;

  return v_offer;
end; $$;

create or replace function admin_delete_offer(p_offer_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  delete from venue_offers where id = p_offer_id;
end; $$;

create or replace function admin_list_offers()
returns table (
  id uuid, venue_id uuid, venue_name text, lat double precision, lon double precision,
  kind text, title text, description text, fine_print text, redeem text,
  starts_at timestamptz, ends_at timestamptz, active_days int[],
  start_minute int, end_minute int, is_active boolean, approved boolean, created_at timestamptz
)
language sql security definer set search_path = public as $$
  select o.id, o.venue_id, v.name, v.lat, v.lon, o.kind, o.title, o.description,
         o.fine_print, o.redeem, o.starts_at, o.ends_at, o.active_days,
         o.start_minute, o.end_minute, o.is_active, o.approved, o.created_at
  from venue_offers o
  join venues v on v.id = o.venue_id
  where exists (select 1 from app_admins where user_id = auth.uid())
  order by o.created_at desc;
$$;

revoke execute on function admin_create_offer(text,text,text,double precision,double precision,text,text,text,text,text,text,text,timestamptz,timestamptz,int[],int,int) from public, anon;
grant  execute on function admin_create_offer(text,text,text,double precision,double precision,text,text,text,text,text,text,text,timestamptz,timestamptz,int[],int,int) to authenticated;
revoke execute on function admin_delete_offer(uuid) from public, anon;
grant  execute on function admin_delete_offer(uuid) to authenticated;
revoke execute on function admin_list_offers() from public, anon;
grant  execute on function admin_list_offers() to authenticated;

notify pgrst, 'reload schema';
