-- 053_venue_tiers.sql — paid placement tiers for bars.
--
--   tier 'none'      → invisible on Deals surfaces (default; not paying)
--   tier 'pin'       → dot on the deals map + offer rows (lowest tier)
--   tier 'poster'    → + branded poster card / artwork map pin
--   tier 'billboard' → + hero carousel on the Deals tab (top tier); also
--                       licenses interstitial + push placements (steps 4–5)
--
-- venue_campaigns carries the branded creative per placement, moderated with
-- the same is_active/approved gates as venue_offers. RLS lets clients read
-- only LIVE campaigns whose venue's tier licenses the placement — so a
-- downgraded bar's poster vanishes without touching the campaign rows.
-- campaign_stats sells the product: daily impressions/taps per campaign.

-- ── 1 · tier on venues ────────────────────────────────────────────────
alter table venues add column if not exists tier text not null default 'none';
do $$ begin
  alter table venues add constraint venues_tier_check
    check (tier in ('none','pin','poster','billboard'));
exception when duplicate_object then null; end $$;

-- Grandfather: venues already carrying an approved offer keep working as
-- pins so the existing Deals map doesn't empty out under this migration.
update venues set tier = 'pin'
 where tier = 'none'
   and id in (select distinct venue_id from venue_offers where approved);

-- ── 2 · campaigns ─────────────────────────────────────────────────────
create table if not exists venue_campaigns (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references venues(id) on delete cascade,
  placement  text not null check (placement in ('poster','billboard','interstitial','push')),
  title      text not null,
  body       text,
  cta_text   text,
  image_url  text,
  starts_at  timestamptz,
  ends_at    timestamptz,
  is_active  boolean not null default true,
  approved   boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists venue_campaigns_venue_idx on venue_campaigns (venue_id);
alter table venue_campaigns enable row level security;

-- Clients read live campaigns only, and only while the venue's tier
-- licenses the placement. Poster art needs poster+; everything else
-- (billboard, interstitial, push) needs the top tier.
drop policy if exists venue_campaigns_select on venue_campaigns;
create policy venue_campaigns_select on venue_campaigns
  for select to authenticated
  using (
    is_active and approved
    and (starts_at is null or starts_at <= now())
    and (ends_at   is null or ends_at   >= now())
    and exists (
      select 1 from venues v
      where v.id = venue_id
        and case placement
              when 'poster' then v.tier in ('poster','billboard')
              else v.tier = 'billboard'
            end
    )
  );
-- No write policies: the admin RPCs below are the only door.

-- ── 3 · stats (what the bar pays for proof of) ────────────────────────
create table if not exists campaign_stats (
  campaign_id uuid not null references venue_campaigns(id) on delete cascade,
  day         date not null default (now()::date),
  impressions int  not null default 0,
  taps        int  not null default 0,
  primary key (campaign_id, day)
);
alter table campaign_stats enable row level security;
drop policy if exists campaign_stats_admin_select on campaign_stats;
create policy campaign_stats_admin_select on campaign_stats
  for select to authenticated
  using (exists (select 1 from app_admins where user_id = auth.uid()));

-- Fire-and-forget counters from the client. Per-call clamp keeps a hostile
-- client from inflating a day's numbers absurdly in one shot.
create or replace function bump_campaign_stats(p_campaign uuid, p_impressions int, p_taps int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_campaign is null then return; end if;
  insert into campaign_stats (campaign_id, day, impressions, taps)
  values (p_campaign, now()::date,
          least(greatest(coalesce(p_impressions,0),0),20),
          least(greatest(coalesce(p_taps,0),0),20))
  on conflict (campaign_id, day) do update
    set impressions = campaign_stats.impressions + excluded.impressions,
        taps        = campaign_stats.taps        + excluded.taps;
end $$;

-- ── 4 · admin RPCs (app_admins-gated, same pattern as 030) ────────────
create or replace function admin_set_venue_tier(p_venue uuid, p_tier text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_tier not in ('none','pin','poster','billboard') then
    raise exception 'bad_tier';
  end if;
  update venues set tier = p_tier where id = p_venue;
end $$;

create or replace function admin_create_campaign(
  p_venue uuid, p_placement text, p_title text, p_body text,
  p_cta text, p_image_url text, p_starts timestamptz, p_ends timestamptz
) returns venue_campaigns
language plpgsql security definer set search_path = public as $$
declare row venue_campaigns;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  -- Admin-created creative is de-facto moderated → approved on insert,
  -- mirroring admin_create_offer.
  insert into venue_campaigns (venue_id, placement, title, body, cta_text,
                               image_url, starts_at, ends_at, is_active, approved)
  values (p_venue, p_placement, p_title, nullif(p_body,''), nullif(p_cta,''),
          nullif(p_image_url,''), p_starts, p_ends, true, true)
  returning * into row;
  return row;
end $$;

create or replace function admin_set_campaign_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  update venue_campaigns set is_active = p_active where id = p_id;
end $$;

create or replace function admin_delete_campaign(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  delete from venue_campaigns where id = p_id;
end $$;

-- Management list: every campaign (incl. inactive/expired) + venue context.
create or replace function admin_list_campaigns()
returns table (
  id uuid, venue_id uuid, venue_name text, venue_tier text,
  placement text, title text, body text, cta_text text, image_url text,
  starts_at timestamptz, ends_at timestamptz, is_active boolean,
  impressions bigint, taps bigint
) language sql security definer set search_path = public as $$
  select c.id, c.venue_id, v.name, v.tier,
         c.placement, c.title, c.body, c.cta_text, c.image_url,
         c.starts_at, c.ends_at, c.is_active,
         coalesce(sum(s.impressions), 0), coalesce(sum(s.taps), 0)
  from venue_campaigns c
  join venues v on v.id = c.venue_id
  left join campaign_stats s on s.campaign_id = c.id
  where exists (select 1 from app_admins where user_id = auth.uid())
  group by c.id, v.name, v.tier
  order by c.created_at desc;
$$;

-- ── 5 · campaign artwork bucket (public read, admin-only write) ───────
insert into storage.buckets (id, name, public)
values ('campaign-art', 'campaign-art', true)
on conflict (id) do nothing;

drop policy if exists campaign_art_insert on storage.objects;
create policy campaign_art_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'campaign-art'
    and exists (select 1 from public.app_admins where user_id = auth.uid())
  );

-- Upsert needs UPDATE (+ the public bucket covers reads).
drop policy if exists campaign_art_update on storage.objects;
create policy campaign_art_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'campaign-art'
    and exists (select 1 from public.app_admins where user_id = auth.uid())
  )
  with check (
    bucket_id = 'campaign-art'
    and exists (select 1 from public.app_admins where user_id = auth.uid())
  );
