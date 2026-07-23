-- 055_offer_rpc_param_defaults.sql
--
-- Real cause of the "PGRST202 could not find function" wall: supabase-swift
-- OMITS nil-valued fields from the JSON body, so leaving description / fine
-- print blank (and "runs all day" on) sends only a SUBSET of the params.
-- PostgREST resolves an RPC by name only when every parameter WITHOUT a
-- default is present — so the missing p_description/p_fine_print/p_code/
-- p_start_minute/p_end_minute made the call unresolvable. (curl worked because
-- it sent all args explicitly; nothing to do with the schema cache or roles.)
--
-- Fix: default every optional parameter so any subset resolves. Postgres
-- requires that once a param has a default, all following params do too, so
-- only the always-sent leading key stays required.

drop function if exists public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text);

create function public.admin_create_offer(
  p_name        text,
  p_address     text default null,
  p_city        text default null,
  p_lat         double precision default 0,
  p_lon         double precision default 0,
  p_external_id text default null,
  p_kind        text default 'price',
  p_title       text default '',
  p_description text default null,
  p_fine_print  text default null,
  p_redeem      text default 'show',
  p_code        text default null,
  p_starts_at   timestamptz default now(),
  p_ends_at     timestamptz default null,
  p_active_days int[] default null,
  p_start_minute int default null,
  p_end_minute  int default null,
  p_placement   text default 'pin',
  p_image_url   text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_venue uuid; v_offer uuid;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_placement not in ('pin','poster','billboard') then raise exception 'bad_placement'; end if;
  if coalesce(p_title,'') = '' then raise exception 'title_required'; end if;

  select id into v_venue from venues
   where (p_external_id is not null and external_id = p_external_id) limit 1;
  if v_venue is null then
    select id into v_venue from venues
     where lower(name) = lower(p_name) and abs(lat - p_lat) < 0.001 and abs(lon - p_lon) < 0.001 limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, source, external_id)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id) returning id into v_venue;
  end if;

  insert into venue_offers (venue_id, kind, title, description, fine_print, redeem, code,
                            starts_at, ends_at, active_days, start_minute, end_minute,
                            is_active, approved, placement, image_url)
  values (v_venue, p_kind, p_title, nullif(p_description,''), nullif(p_fine_print,''),
          coalesce(p_redeem,'show'), p_code, coalesce(p_starts_at, now()), p_ends_at, p_active_days,
          p_start_minute, p_end_minute, true, true, p_placement, nullif(p_image_url,''))
  returning id into v_offer;
  return v_offer;
end $$;

drop function if exists public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, int[], int, int, text, text);

create function public.admin_update_offer(
  p_offer_id    uuid,
  p_kind        text default 'price',
  p_title       text default '',
  p_description text default null,
  p_fine_print  text default null,
  p_ends_at     timestamptz default null,
  p_active_days int[] default null,
  p_start_minute int default null,
  p_end_minute  int default null,
  p_placement   text default 'pin',
  p_image_url   text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_placement not in ('pin','poster','billboard') then raise exception 'bad_placement'; end if;
  update venue_offers set
    kind         = p_kind,
    title        = p_title,
    description  = nullif(p_description,''),
    fine_print   = nullif(p_fine_print,''),
    ends_at      = p_ends_at,
    active_days  = p_active_days,
    start_minute = p_start_minute,
    end_minute   = p_end_minute,
    placement    = p_placement,
    image_url    = coalesce(nullif(p_image_url,''), image_url)
  where id = p_offer_id;
end $$;

grant execute on function public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text
) to anon, authenticated, service_role;
grant execute on function public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, int[], int, int, text, text
) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
