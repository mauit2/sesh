-- 060_city_radius_and_display_schedule.sql
--
--  1) Deal push reaches the whole CITY, not just a 5 km circle: bump the
--     send_venue_push radius 5 km → 25 km. (The client interstitial radius is
--     bumped to match in code.)
--  2) Per-campaign display schedule: show_on_valid_only. When true, the card
--     only DISPLAYS on its valid days + time window (a day-of reminder, e.g.
--     "only show Wednesday evenings for the quiz"), instead of marketing across
--     the whole starts_at..ends_at window. Display gating is client-side (needs
--     the viewer's weekday + local time); the column just carries the intent.

alter table venue_offers add column if not exists show_on_valid_only boolean not null default false;

-- ── send_venue_push: 25 km city radius ────────────────────────────────────
create or replace function public.send_venue_push(
  p_offer_id uuid, p_title text, p_body text
) returns int
language plpgsql security definer set search_path = public, private as $$
declare
  v_venue uuid; v_lat double precision; v_lon double precision;
  v_recent int; v_hour int; v_count int := 0;
  c_radius_m constant double precision := 25000;   -- whole city
  c_fresh    constant interval := interval '30 days';
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if coalesce(p_title,'') = '' or coalesce(p_body,'') = '' then raise exception 'empty'; end if;

  select venue_id into v_venue from venue_offers where id = p_offer_id;
  if v_venue is null then raise exception 'no_offer'; end if;
  select lat, lon into v_lat, v_lon from venues where id = v_venue;

  select count(*) into v_recent from venue_push_log
   where venue_id = v_venue and created_at > now() - interval '7 days';
  if v_recent >= 3 then raise exception 'weekly_cap'; end if;

  v_hour := extract(hour from (now() at time zone 'Europe/Stockholm'))::int;
  if v_hour >= 4 and v_hour < 10 then raise exception 'quiet_hours'; end if;

  perform private.notify_push(p.id, p_title, p_body,
            jsonb_build_object('type','deal','venue_id', v_venue, 'offer_id', p_offer_id))
     from profiles p
    where p.deals_push_opt_in
      and p.deals_lat is not null and p.deals_lon is not null
      and p.deals_loc_at > now() - c_fresh
      and (v_lat is null or v_lon is null
           or public.haversine_m(p.deals_lat, p.deals_lon, v_lat, v_lon) <= c_radius_m);

  select count(*) into v_count from profiles p
    where p.deals_push_opt_in
      and p.deals_lat is not null and p.deals_lon is not null
      and p.deals_loc_at > now() - c_fresh
      and (v_lat is null or v_lon is null
           or public.haversine_m(p.deals_lat, p.deals_lon, v_lat, v_lon) <= c_radius_m);

  insert into venue_push_log (venue_id, offer_id, sent_by, title, body, recipient_count)
  values (v_venue, p_offer_id, auth.uid(), p_title, p_body, v_count);
  return v_count;
end $$;
grant execute on function public.send_venue_push(uuid, text, text) to authenticated, service_role;

-- ── admin_create_offer: append p_show_on_valid_only ───────────────────────
drop function if exists public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean);

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
  p_image_url   text default null,
  p_billboard_image_url text default null,
  p_interstitial boolean default false,
  p_show_on_valid_only boolean default false
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_venue uuid; v_offer uuid;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
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
                            is_active, approved, placement, image_url, billboard_image_url,
                            interstitial, show_on_valid_only)
  values (v_venue, p_kind, p_title, nullif(p_description,''), nullif(p_fine_print,''),
          coalesce(p_redeem,'show'), p_code, coalesce(p_starts_at, now()), p_ends_at, p_active_days,
          p_start_minute, p_end_minute, true, true, p_placement,
          nullif(p_image_url,''), nullif(p_billboard_image_url,''),
          coalesce(p_interstitial, false), coalesce(p_show_on_valid_only, false))
  returning id into v_offer;
  return v_offer;
end $$;

-- ── admin_update_offer: append p_show_on_valid_only ───────────────────────
drop function if exists public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean);

create function public.admin_update_offer(
  p_offer_id    uuid,
  p_kind        text default 'price',
  p_title       text default '',
  p_description text default null,
  p_fine_print  text default null,
  p_starts_at   timestamptz default null,
  p_ends_at     timestamptz default null,
  p_active_days int[] default null,
  p_start_minute int default null,
  p_end_minute  int default null,
  p_placement   text default 'pin',
  p_image_url   text default null,
  p_billboard_image_url text default null,
  p_interstitial boolean default false,
  p_show_on_valid_only boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if p_placement not in ('pin','poster','billboard') then raise exception 'bad_placement'; end if;
  update venue_offers set
    kind         = p_kind,
    title        = p_title,
    description  = nullif(p_description,''),
    fine_print   = nullif(p_fine_print,''),
    starts_at    = coalesce(p_starts_at, starts_at),
    ends_at      = p_ends_at,
    active_days  = p_active_days,
    start_minute = p_start_minute,
    end_minute   = p_end_minute,
    placement    = p_placement,
    image_url           = coalesce(nullif(p_image_url,''), image_url),
    billboard_image_url = coalesce(nullif(p_billboard_image_url,''), billboard_image_url),
    interstitial = coalesce(p_interstitial, false),
    show_on_valid_only = coalesce(p_show_on_valid_only, false)
  where id = p_offer_id;
end $$;

-- ── admin_list_offers: return show_on_valid_only ──────────────────────────
drop function if exists admin_list_offers();
create function admin_list_offers()
returns table (
  id uuid, venue_id uuid, venue_name text, lat double precision, lon double precision,
  kind text, title text, description text, fine_print text, redeem text,
  starts_at timestamptz, ends_at timestamptz, active_days int[],
  start_minute int, end_minute int, is_active boolean, approved boolean,
  created_at timestamptz, placement text, image_url text, billboard_image_url text,
  interstitial boolean, show_on_valid_only boolean,
  impressions bigint, taps bigint,
  week_impressions bigint, week_taps bigint
) language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then return; end if;
  delete from campaign_stats
   where campaign_id in (select o.id from venue_offers o where o.ends_at is not null and o.ends_at < now());
  delete from venue_offers o where o.ends_at is not null and o.ends_at < now();
  return query
  select o.id, o.venue_id, v.name, v.lat, v.lon,
         o.kind, o.title, o.description, o.fine_print, o.redeem,
         o.starts_at, o.ends_at, o.active_days, o.start_minute, o.end_minute,
         o.is_active, o.approved, o.created_at, o.placement, o.image_url, o.billboard_image_url,
         o.interstitial, o.show_on_valid_only,
         coalesce(sum(s.impressions), 0), coalesce(sum(s.taps), 0),
         coalesce(sum(s.impressions) filter (where s.day >= current_date - 6), 0),
         coalesce(sum(s.taps)        filter (where s.day >= current_date - 6), 0)
  from venue_offers o
  join venues v on v.id = o.venue_id
  left join campaign_stats s on s.campaign_id = o.id
  group by o.id, v.name, v.lat, v.lon
  order by o.created_at desc;
end $$;

grant execute on function public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text, text, text,
  text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean, boolean
) to anon, authenticated, service_role;
grant execute on function public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean, boolean
) to anon, authenticated, service_role;
grant execute on function admin_list_offers() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
