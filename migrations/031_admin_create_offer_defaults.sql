-- 031_admin_create_offer_defaults.sql
--
-- Fix: the in-app "Save special" silently failed. admin_create_offer (030) had
-- NO defaults on any parameter, so PostgREST could only resolve the call when
-- the client sent ALL 17 named args. When the client omits null optionals
-- (e.g. no time window / no code), the named-arg set no longer matches any
-- function and PostgREST returns "function not found".
--
-- Giving every parameter a default makes the RPC resolvable for any subset of
-- args the client sends. Body is unchanged; it still validates admin + title.

drop function if exists admin_create_offer(
  text, text, text, double precision, double precision, text, text, text, text,
  text, text, text, timestamptz, timestamptz, int[], int, int
);

create function admin_create_offer(
  p_name         text default '',
  p_address      text default null,
  p_city         text default null,
  p_lat          double precision default 0,
  p_lon          double precision default 0,
  p_external_id  text default null,
  p_kind         text default 'price',
  p_title        text default '',
  p_description  text default null,
  p_fine_print   text default null,
  p_redeem       text default 'show',
  p_code         text default null,
  p_starts_at    timestamptz default null,
  p_ends_at      timestamptz default null,
  p_active_days  int[] default null,
  p_start_minute int default null,
  p_end_minute   int default null
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

  if coalesce(p_external_id, '') <> '' then
    select id into v_venue from venues where external_id = p_external_id limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, is_featured, source, external_id)
    values (p_name, nullif(p_address, ''), nullif(p_city, ''), p_lat, p_lon,
            true, 'curated', nullif(p_external_id, ''))
    returning id into v_venue;
  else
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

revoke execute on function admin_create_offer(text,text,text,double precision,double precision,text,text,text,text,text,text,text,timestamptz,timestamptz,int[],int,int) from public, anon;
grant  execute on function admin_create_offer(text,text,text,double precision,double precision,text,text,text,text,text,text,text,timestamptz,timestamptz,int[],int,int) to authenticated;

notify pgrst, 'reload schema';
