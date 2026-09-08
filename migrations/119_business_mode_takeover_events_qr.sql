-- 119: Business mode. Creating a business account turns the account into
-- the bar (name + @username), and cancelling the subscription turns it back.
-- Business events (Business+), multi-image posts, owner check-in QR.
-- Applied 2026-09-08 as business_mode_takeover_events_qr.

alter table public.profiles add column if not exists business_id uuid references public.businesses(id) on delete set null;
create index if not exists profiles_business_idx on public.profiles(business_id);

alter table public.businesses
  add column if not exists username text,
  add column if not exists prior_name text,
  add column if not exists prior_username text,
  add column if not exists prior_avatar_url text,
  add column if not exists ended_at timestamptz;
alter table public.businesses drop constraint if exists businesses_status_check;
alter table public.businesses add constraint businesses_status_check
  check (status in ('pending','approved','rejected','suspended','ended'));

alter table public.business_posts add column if not exists image_urls text[];
update public.business_posts set image_urls = array[image_url] where image_urls is null;

create table if not exists public.business_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null,
  starts_at timestamptz not null,
  image_url text,
  created_at timestamptz not null default now(),
  cancelled_at timestamptz
);
alter table public.business_events enable row level security;
create index if not exists business_events_business_idx on public.business_events(business_id, starts_at);

-- private.biz_username(name)      → unique lowercase handle from the venue name
-- private.business_takeover(id)   → stores prior name/handle/avatar, sets the
--                                    profile's name, username, business_id, avatar
-- private.business_revert(id)     → restores the profile; soft-deletes posts;
--                                    cancels boosts, cards, pushes, orders, events;
--                                    deactivates deals; status 'ended'; off the map
-- business_register()             → one business per account; takes over on insert
-- business_sync_subscription()    → tier lapsing after a paid tier reverts
-- run_business_presence()         → reverts a day after expiry (cron, every 10 min)
-- business_update_profile()       → the logo becomes the account avatar
-- business_create_post(uuid, text[], real, text, timestamptz, uuid)
--                                 → 1 picture on Business, ≤10 on Business+
-- business_create_event / business_cancel_event / business_events_upcoming
-- business_qr_token(business)     → ensure_qr_token(venue) for the owner
-- reads (business_profiles_public, business_profile, business_feed, boosts_live,
--   business_mine, business_overview) gain username, image_urls, events, prior_*, qr_token
-- data: the Perth test business ended; nightsesh became the "Moreno Pizza"
--   business (Business+ until 2026-10-08) on the Moreno Pizza venue.
