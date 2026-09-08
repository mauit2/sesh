-- 117: Sejdel Business as subscriptions (Business / Business+), followable
-- business accounts with posts, boosts sold as view packs, cards & pushes
-- gated to Business+. Replaces the pin / poster / billboard packs.
-- Applied 2026-09-08 as business_subscriptions_follows_posts_boosts.

alter table public.businesses
  add column if not exists tier text not null default 'none',
  add column if not exists tier_product_id text,
  add column if not exists tier_expires_at timestamptz,
  add column if not exists apple_original_transaction_id text,
  add column if not exists tier_synced_at timestamptz,
  add column if not exists logo_url text,
  add column if not exists poster_url text,
  add column if not exists tagline text;
alter table public.businesses drop constraint if exists businesses_tier_check;
alter table public.businesses add constraint businesses_tier_check check (tier in ('none','business','plus'));

create table if not exists public.business_subscription_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id text, tier text, expires_at timestamptz,
  apple_original_transaction_id text, apple_transaction_id text, apple_jws text,
  created_at timestamptz not null default now()
);
alter table public.business_subscription_log enable row level security;

create or replace function private.biz_tier(p_business uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when b.status = 'approved' and b.tier <> 'none'
                     and (b.tier_expires_at is null or b.tier_expires_at > now())
                then b.tier else 'none' end
    from businesses b where b.id = p_business), 'none')
$$;

create table if not exists public.business_follows (
  user_id uuid not null references public.profiles(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, business_id)
);
alter table public.business_follows enable row level security;
drop policy if exists business_follows_own on public.business_follows;
create policy business_follows_own on public.business_follows
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create index if not exists business_follows_business_idx on public.business_follows(business_id);

create or replace function public.follow_business(p_business uuid, p_on boolean) returns integer
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_on then
    if private.biz_tier(p_business) = 'none' then raise exception 'no_business'; end if;
    insert into business_follows (user_id, business_id) values (v_uid, p_business) on conflict do nothing;
  else
    delete from business_follows where user_id = v_uid and business_id = p_business;
  end if;
  return (select count(*) from business_follows where business_id = p_business);
end $$;

create table if not exists public.business_posts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  image_url text not null,
  image_ratio real not null default 1,
  caption text,
  event_at timestamptz,
  offer_id uuid references public.venue_offers(id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table public.business_posts enable row level security;
create index if not exists business_posts_business_idx on public.business_posts(business_id, created_at desc);

create table if not exists public.business_boosts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  post_id uuid not null references public.business_posts(id) on delete cascade,
  product_id text not null,
  goal_views integer not null,
  views integer not null default 0,
  taps integer not null default 0,
  status text not null default 'pending' check (status in ('pending','live','done','cancelled')),
  apple_transaction_id text unique,
  apple_original_transaction_id text,
  apple_jws text,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  done_at timestamptz
);
alter table public.business_boosts enable row level security;
create index if not exists business_boosts_live_idx on public.business_boosts(status) where status = 'live';

update public.business_orders set product_id = null
 where product_id like 'sejdel.biz.pin.%' or product_id like 'sejdel.biz.poster.%' or product_id like 'sejdel.biz.billboard.%';
update public.business_orders set status = 'cancelled'
 where kind in ('pin','poster','billboard') and status in ('pending','approved') and not paid;
delete from public.business_products where kind in ('pin','poster','billboard');
alter table public.business_products drop constraint if exists business_products_kind_check;
alter table public.business_products add constraint business_products_kind_check
  check (kind in ('subscription','boost','card','push'));
insert into public.business_products (product_id, kind, quantity, amount_sek, label, sort) values
  ('sejdel.biz.business.monthly', 'subscription', 1,    299,  'Sejdel Business · monthly',  1),
  ('sejdel.biz.plus.monthly',     'subscription', 2,    899,  'Sejdel Business+ · monthly', 2),
  ('sejdel.biz.boost.1000',       'boost',        1000, 499,  'Boost · 1,000 views',        20),
  ('sejdel.biz.boost.2500',       'boost',        2500, 999,  'Boost · 2,500 views',        21),
  ('sejdel.biz.boost.5000',       'boost',        5000, 1799, 'Boost · 5,000 views',        22)
on conflict (product_id) do update
  set kind = excluded.kind, quantity = excluded.quantity, amount_sek = excluded.amount_sek,
      label = excluded.label, sort = excluded.sort;

-- presence, subscription sync, profile edits, deals, cards/pushes (Business+),
-- posts, boosts, bump_campaign_stats with boost goals, public reads
-- (business_profiles_public / business_profile / business_feed / boosts_live),
-- business_mine, business_overview, admin_business_queue,
-- admin_business_set_status, run_business_presence + cron: see the Supabase
-- migration of the same name for the full function bodies; 119 and 120
-- restate the ones that changed afterwards.
