-- 054_campaigns_on_offers.sql — one "campaign" object, placement included.
--
-- Feedback round on 053: a separate campaigns table + manual tier menu made
-- two things the admin has to keep in sync. Unified model instead:
--
--   campaign = venue_offers row + placement ('pin' | 'poster' | 'billboard')
--              + optional artwork (image_url — column existed since 029).
--
--   • venues.tier is now DERIVED: a trigger keeps it at the venue's highest
--     live placement, so there is no tier switch to forget. Charge per
--     campaign level; the surfaces follow automatically.
--   • Expired campaigns (ends_at in the past) are DELETED when the admin
--     list loads — user-facing surfaces already hid them via RLS.
--   • campaign_stats now keys on the creative's id (an offer id) — FK to
--     venue_campaigns dropped. venue_campaigns stays for the future
--     interstitial/push placements, which aren't redeemable offers.

-- ── 1 · placement on venue_offers ─────────────────────────────────────
alter table venue_offers add column if not exists placement text not null default 'pin';
do $$ begin
  alter table venue_offers add constraint venue_offers_placement_check
    check (placement in ('pin','poster','billboard'));
exception when duplicate_object then null; end $$;

-- ── 2 · venues.tier derives from live campaigns ───────────────────────
create or replace function sync_venue_tier() returns trigger
language plpgsql security definer set search_path = public as $$
declare v uuid; best int; t text;
begin
  v := coalesce(NEW.venue_id, OLD.venue_id);
  select coalesce(max(case placement
                        when 'billboard' then 3
                        when 'poster'    then 2
                        else 1
                      end), 0)
    into best
    from venue_offers
   where venue_id = v and is_active and approved
     and (ends_at is null or ends_at >= now());
  t := case best when 3 then 'billboard' when 2 then 'poster'
                 when 1 then 'pin' else 'none' end;
  update venues set tier = t where id = v and tier is distinct from t;
  return null;
end $$;

drop trigger if exists trg_sync_venue_tier on venue_offers;
create trigger trg_sync_venue_tier
  after insert or update or delete on venue_offers
  for each row execute function sync_venue_tier();

-- Backfill: recompute every venue's tier from its live offers right now.
update venues v set tier = coalesce((
  select case max(case o.placement when 'billboard' then 3
                                   when 'poster' then 2 else 1 end)
           when 3 then 'billboard' when 2 then 'poster' when 1 then 'pin'
         end
  from venue_offers o
  where o.venue_id = v.id and o.is_active and o.approved
    and (o.ends_at is null or o.ends_at >= now())
), 'none');

-- ── 3 · stats key on the creative id, whatever table it lives in ──────
alter table campaign_stats drop constraint if exists campaign_stats_campaign_id_fkey;

-- ── 4 · admin RPCs ────────────────────────────────────────────────────
-- Create gains placement + image_url. The old signature is dropped (the
-- app's admin panel is the only caller and ships alongside this).
drop function if exists admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int);

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
  p_end_minute  int,
  p_placement   text default 'pin',
  p_image_url   text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_venue uuid; v_offer uuid;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_placement not in ('pin','poster','billboard') then
    raise exception 'bad_placement';
  end if;

  -- Find-or-create the venue, matching MapKit identity first (same logic
  -- as the 030/031 create).
  select id into v_venue from venues
   where (p_external_id is not null and external_id = p_external_id)
   limit 1;
  if v_venue is null then
    select id into v_venue from venues
     where lower(name) = lower(p_name)
       and abs(lat - p_lat) < 0.001 and abs(lon - p_lon) < 0.001
     limit 1;
  end if;
  if v_venue is null then
    insert into venues (name, address, city, lat, lon, source, external_id)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id)
    returning id into v_venue;
  end if;

  insert into venue_offers (venue_id, kind, title, description, fine_print,
                            redeem, code, starts_at, ends_at, active_days,
                            start_minute, end_minute, is_active, approved,
                            placement, image_url)
  values (v_venue, p_kind, p_title, nullif(p_description,''), nullif(p_fine_print,''),
          coalesce(p_redeem,'show'), p_code, p_starts_at, p_ends_at, p_active_days,
          p_start_minute, p_end_minute, true, true,
          p_placement, nullif(p_image_url,''))
  returning id into v_offer;
  return v_offer;
end $$;

-- Edit an existing campaign in place (extend the end date, change the
-- offer copy, swap artwork, move placement up/down the price ladder).
create or replace function admin_update_offer(
  p_offer_id    uuid,
  p_kind        text,
  p_title       text,
  p_description text,
  p_fine_print  text,
  p_ends_at     timestamptz,
  p_active_days int[],
  p_start_minute int,
  p_end_minute  int,
  p_placement   text,
  p_image_url   text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_placement not in ('pin','poster','billboard') then
    raise exception 'bad_placement';
  end if;
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

-- List: purge expired campaigns first (the requested auto-delete), then
-- return the survivors with placement, artwork, and lifetime stats.
drop function if exists admin_list_offers();
create or replace function admin_list_offers()
returns table (
  id uuid, venue_id uuid, venue_name text, lat double precision, lon double precision,
  kind text, title text, description text, fine_print text, redeem text,
  starts_at timestamptz, ends_at timestamptz, active_days int[],
  start_minute int, end_minute int, is_active boolean, approved boolean,
  created_at timestamptz, placement text, image_url text,
  impressions bigint, taps bigint
) language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    return;
  end if;
  -- Auto-delete run-out campaigns + their stats rows.
  delete from campaign_stats
   where campaign_id in (select o.id from venue_offers o
                          where o.ends_at is not null and o.ends_at < now());
  delete from venue_offers o where o.ends_at is not null and o.ends_at < now();

  return query
  select o.id, o.venue_id, v.name, v.lat, v.lon,
         o.kind, o.title, o.description, o.fine_print, o.redeem,
         o.starts_at, o.ends_at, o.active_days,
         o.start_minute, o.end_minute, o.is_active, o.approved,
         o.created_at, o.placement, o.image_url,
         coalesce(sum(s.impressions), 0), coalesce(sum(s.taps), 0)
  from venue_offers o
  join venues v on v.id = o.venue_id
  left join campaign_stats s on s.campaign_id = o.id
  group by o.id, v.name, v.lat, v.lon
  order by o.created_at desc;
end $$;

-- PostgREST caches function signatures; nudge it to pick up the new/changed
-- admin_* RPCs immediately instead of erroring with PGRST202 until the next
-- automatic reload.
notify pgrst, 'reload schema';

-- Dropping + recreating a function resets its EXECUTE grants to the default;
-- make the app roles' access explicit so PostgREST resolves it for the
-- authenticated role (a missing grant surfaces as a confusing 404, not 403).
grant execute on function public.admin_create_offer(
  text, text, text, double precision, double precision, text, text, text,
  text, text, text, text, timestamptz, timestamptz, int[], int, int, text, text
) to anon, authenticated, service_role;
grant execute on function public.admin_update_offer(
  uuid, text, text, text, text, timestamptz, int[], int, int, text, text
) to anon, authenticated, service_role;
notify pgrst, 'reload schema';
