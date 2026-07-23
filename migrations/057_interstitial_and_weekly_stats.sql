-- 057_interstitial_and_weekly_stats.sql
--
--  Step 4 (interstitial): an offer can be flagged as an app-open promo — a
--    full-screen card shown once per user when they open the app, geo-scoped
--    to their city, with the bar's image + offer. The flag lives on the offer;
--    the "once per user" cap is enforced client-side (UserDefaults) so we add
--    no per-user server writes / egress.
--  Step 6 (stats): admin_list_offers now also returns last-7-day impressions
--    and taps so the admin panel can show a "this week" line per campaign.
--
--  No RLS change: the public venue_offers_read policy already returns whole
--  rows, so `interstitial` flows to the client through the existing select.

alter table venue_offers add column if not exists interstitial boolean not null default false;

-- ── admin_create_offer: append p_interstitial (defaulted, so the 14-param
--    app body still resolves — see migration 055 on PGRST202). ──────────────
drop function if exists public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text);

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
  p_interstitial boolean default false
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
                            interstitial)
  values (v_venue, p_kind, p_title, nullif(p_description,''), nullif(p_fine_print,''),
          coalesce(p_redeem,'show'), p_code, coalesce(p_starts_at, now()), p_ends_at, p_active_days,
          p_start_minute, p_end_minute, true, true, p_placement,
          nullif(p_image_url,''), nullif(p_billboard_image_url,''), coalesce(p_interstitial, false))
  returning id into v_offer;
  return v_offer;
end $$;

-- ── admin_update_offer: append p_interstitial ─────────────────────────────
drop function if exists public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text);

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
  p_interstitial boolean default false
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
    interstitial = coalesce(p_interstitial, false)
  where id = p_offer_id;
end $$;

-- ── admin_list_offers: return interstitial + last-7-day stats ──────────────
drop function if exists admin_list_offers();
create function admin_list_offers()
returns table (
  id uuid, venue_id uuid, venue_name text, lat double precision, lon double precision,
  kind text, title text, description text, fine_print text, redeem text,
  starts_at timestamptz, ends_at timestamptz, active_days int[],
  start_minute int, end_minute int, is_active boolean, approved boolean,
  created_at timestamptz, placement text, image_url text, billboard_image_url text,
  interstitial boolean,
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
         o.interstitial,
         coalesce(sum(s.impressions), 0), coalesce(sum(s.taps), 0),
         coalesce(sum(s.impressions) filter (where s.day >= current_date - 6), 0),
         coalesce(sum(s.taps)        filter (where s.day >= current_date - 6), 0)
  from venue_offers o
  join venues v on v.id = o.venue_id
  left join campaign_stats s on s.campaign_id = o.id
  group by o.id, v.name, v.lat, v.lon
  order by o.created_at desc;
end $$;

-- Re-grant (drop+recreate resets EXECUTE grants) and nudge PostgREST.
grant execute on function public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text, text, text,
  text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean
) to anon, authenticated, service_role;
grant execute on function public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text, text, boolean
) to anon, authenticated, service_role;
grant execute on function admin_list_offers() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
