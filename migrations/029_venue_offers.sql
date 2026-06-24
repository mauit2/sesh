-- 029_venue_offers.sql
--
-- Phase A of venue marketing: promotional OFFERS attached to venues, surfaced
-- on an interactive "deals near you" map. Distinct from `venue_specials`
-- (003) — those are drink menu items carrying volume_ml/abv that plug into the
-- BAC math at check-in. Offers are marketing: price deals, free entry, bundles,
-- happy hours. They aren't logged as drinks; they're discovered and shown.
--
-- Curation model (Phase A): venues do NOT self-publish yet. There are no
-- INSERT/UPDATE/DELETE policies, so only the service role (us, via SQL / an
-- admin tool) can write offers. Clients get read-only access to offers that are
-- active, approved, and not past their end date. Self-serve venue onboarding +
-- ownership verification + billing come in Phase B/C.

create table if not exists venue_offers (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references venues(id) on delete cascade,
  -- 'price' | 'free_entry' | 'bundle' | 'happy_hour' | 'event'
  kind         text not null default 'price',
  title        text not null,                 -- "39 kr stora stark"
  description  text,                           -- "Show this at the bar"
  fine_print   text,                           -- "Tap to reveal · 20+"
  -- 'show' (eyeball at the bar) | 'code' (reveal a code) | 'scan' (Phase C)
  redeem       text not null default 'show',
  code         text,                           -- nullable; for redeem != 'show'
  starts_at    timestamptz,                    -- date range (null = always)
  ends_at      timestamptz,
  active_days  int[],                          -- 0=Sun..6=Sat; null = every day
  start_minute int,                            -- local minutes from midnight; null = all day
  end_minute   int,
  is_active    boolean not null default true,  -- venue/admin on-off switch
  approved     boolean not null default false, -- moderation gate (default off)
  image_url    text,
  created_at   timestamptz not null default now()
);

create index if not exists venue_offers_venue_idx on venue_offers (venue_id);
create index if not exists venue_offers_live_idx
  on venue_offers (is_active, approved) where is_active and approved;

alter table venue_offers enable row level security;

-- Read-only for clients: only live (active + approved + not expired) offers.
drop policy if exists venue_offers_read on venue_offers;
create policy venue_offers_read on venue_offers
  for select to anon, authenticated
  using (is_active and approved and (ends_at is null or ends_at > now()));

grant select on venue_offers to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Seed: a few Göteborg venues + demo offers covering the offer kinds the
-- product is being designed around (price / free entry / bundle / happy hour).
-- Handelspuben already exists from migration 003; the other two carry
-- APPROXIMATE city-centre coordinates — fix them against the real addresses
-- before relying on the map placement.
-- ---------------------------------------------------------------------------

insert into venues (name, address, city, lat, lon, is_featured)
select 'Pustervik', 'Järntorgsgatan 12', 'Göteborg', 57.6996, 11.9558, true
where not exists (select 1 from venues where name = 'Pustervik');

insert into venues (name, address, city, lat, lon, is_featured)
select 'BrewDog Göteborg', 'Kungsgatan 14', 'Göteborg', 57.7029, 11.9665, true
where not exists (select 1 from venues where name = 'BrewDog Göteborg');

-- Handelspuben — free shot with any jug (bundle)
insert into venue_offers (venue_id, kind, title, description, fine_print, redeem, approved)
select v.id, 'bundle', 'Free shot with any jug',
       'Order any 50 cl jug, get a shot on the house. Show this at the bar.',
       'One per guest · 20+', 'show', true
from venues v
where v.name = 'Handelspuben'
  and not exists (select 1 from venue_offers o where o.venue_id = v.id and o.title = 'Free shot with any jug');

-- Pustervik — free entry before 23:00 (free_entry, show)
insert into venue_offers (venue_id, kind, title, description, fine_print, redeem, start_minute, end_minute, approved)
select v.id, 'free_entry', 'Free entry before 23:00',
       'Skip the cover — show this screen at the door before 23:00.',
       'Valid nightly until 23:00', 'show', 0, 1380, true
from venues v
where v.name = 'Pustervik'
  and not exists (select 1 from venue_offers o where o.venue_id = v.id and o.title = 'Free entry before 23:00');

-- BrewDog — happy hour 16–19, 45 kr beers (happy_hour, price)
insert into venue_offers (venue_id, kind, title, description, fine_print, redeem, active_days, start_minute, end_minute, approved)
select v.id, 'happy_hour', 'Happy hour: 45 kr beers',
       'Selected drafts 45 kr, every day 16:00–19:00.',
       'Selected lines only', 'show', null, 960, 1140, true
from venues v
where v.name = 'BrewDog Göteborg'
  and not exists (select 1 from venue_offers o where o.venue_id = v.id and o.title = 'Happy hour: 45 kr beers');
