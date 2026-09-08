-- 125: stop trusting the phone about money.
--
-- Until now a bar's subscription and its consumable purchases were granted on
-- the client's word (117). This wires the database to Apple:
--
--   * private.appstore_check(transaction_id) asks the appstore-verify edge
--     function, which asks Apple's App Store Server API with our signed key.
--     Whatever Apple says is used; the client's own numbers are ignored.
--   * public.appstore_apply(...) is the write path for the appstore-notify
--     webhook (renewals, lapses, cancellations, refunds). service_role only.
--
-- Fails closed: if Apple has never heard of the transaction, nothing is
-- granted. Local .storekit testing in Xcode produces transactions Apple does
-- not know, so flip private.app_config.appstore_strict to 'false' to test that
-- way, and back to 'true' before launch.
--
-- Applied 2026-09-08 as appstore_server_verification.

create extension if not exists http with schema extensions;

-- Small private key/value store. No grants: only security-definer functions
-- (which run as the owner) ever read it.
create table if not exists private.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

insert into private.app_config (key, value) values
  ('appstore_strict', 'true'),
  ('appstore_verify_url', 'https://lltuozmbxacxiepardys.supabase.co/functions/v1/appstore-verify')
on conflict (key) do nothing;

-- A shared secret so only we can call the verify endpoint. Generated once.
insert into private.app_config (key, value)
select 'internal_secret', encode(extensions.gen_random_bytes(32), 'hex')
on conflict (key) do nothing;

-- ── Ask Apple whether a transaction is real ─────────────────────────────────
-- Returns Apple's own view of the transaction, or raises. NULL only when
-- strict mode is deliberately off.
create or replace function private.appstore_check(p_transaction_id text)
returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare v_url text; v_secret text; v_strict boolean; v_body text; v_res jsonb;
begin
  select (value = 'true') into v_strict from private.app_config where key = 'appstore_strict';
  if not coalesce(v_strict, true) then return null; end if;

  if coalesce(p_transaction_id, '') = '' then raise exception 'no_transaction'; end if;
  select value into v_url    from private.app_config where key = 'appstore_verify_url';
  select value into v_secret from private.app_config where key = 'internal_secret';
  if v_url is null or v_secret is null then raise exception 'verify_not_configured'; end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    select content into v_body from extensions.http((
      'POST',
      v_url,
      array[extensions.http_header('x-sejdel-secret', v_secret)],
      'application/json',
      json_build_object('transaction_id', p_transaction_id)::text
    )::extensions.http_request);
  exception when others then
    raise exception 'verify_unreachable';
  end;

  v_res := v_body::jsonb;
  if coalesce((v_res->>'ok')::boolean, false) then
    return v_res->'transaction';
  end if;
  raise exception 'unverified_%', coalesce(v_res->>'reason', 'unknown');
end $$;

-- ── The subscription, as reported by the app (now checked) ──────────────────
create or replace function public.business_sync_subscription(
  p_business uuid, p_product_id text, p_original_transaction_id text default null,
  p_expires_at timestamptz default null, p_transaction_id text default null, p_jws text default null)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare b public.businesses; v_tier text; v_was text; v_fact jsonb;
        v_product text; v_expires timestamptz; v_orig text; v_token uuid;
begin
  b := private.business_for_owner(p_business, false);
  v_was := private.biz_tier(b.id);

  -- Apple's answer wins over anything the phone sent.
  v_fact := private.appstore_check(p_transaction_id);
  if v_fact is not null then
    v_product := v_fact->>'product_id';
    v_expires := nullif(v_fact->>'expires_at', '')::timestamptz;
    v_orig    := nullif(v_fact->>'original_transaction_id', '');
    begin v_token := nullif(v_fact->>'app_account_token', '')::uuid; exception when others then v_token := null; end;
    -- The purchase was stamped with the business it was made for.
    if v_token is not null and v_token <> b.id then raise exception 'wrong_business'; end if;
    if nullif(v_fact->>'revoked_at', '') is not null then v_expires := now() - interval '1 second'; end if;
  else
    v_product := p_product_id; v_expires := p_expires_at; v_orig := p_original_transaction_id;
  end if;

  v_tier := case v_product
              when 'sejdel.biz.business.monthly' then 'business'
              when 'sejdel.biz.plus.monthly'     then 'plus'
              else 'none' end;
  if v_product is not null and v_tier = 'none' then raise exception 'no_product'; end if;
  if v_expires is not null and v_expires <= now() then v_tier := 'none'; end if;

  insert into business_subscription_log (business_id, product_id, tier, expires_at,
                                         apple_original_transaction_id, apple_transaction_id, apple_jws)
  values (b.id, v_product, v_tier, v_expires, v_orig, p_transaction_id, p_jws);

  if v_tier = 'none' and v_was <> 'none' and b.tier_product_id is not null then
    perform private.business_revert(b.id);
    return jsonb_build_object('tier', 'none', 'reverted', true);
  end if;

  update businesses
     set tier = v_tier,
         tier_product_id = case when v_tier = 'none' then null else v_product end,
         tier_expires_at = case when v_tier = 'none' then null else v_expires end,
         apple_original_transaction_id = coalesce(v_orig, apple_original_transaction_id),
         tier_synced_at = now()
   where id = b.id;
  perform private.business_sync_presence(b.id);
  return jsonb_build_object('tier', private.biz_tier(b.id), 'expires_at', v_expires, 'reverted', false);
end $$;

-- ── Consumables: the card/push order, and the boost ─────────────────────────
create or replace function public.business_mark_paid(
  p_order uuid, p_transaction_id text, p_product_id text,
  p_original_transaction_id text default null, p_jws text default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare ord public.business_orders; b public.businesses; v_fact jsonb; v_product text;
begin
  select * into ord from business_orders where id = p_order;
  if ord.id is null then raise exception 'no_order'; end if;
  b := private.business_for_owner(ord.business_id, false);
  if ord.status <> 'approved' then raise exception 'not_approved_order'; end if;
  if ord.paid then return; end if;
  if coalesce(p_transaction_id,'') = '' then raise exception 'no_transaction'; end if;
  if exists (select 1 from business_orders where apple_transaction_id = p_transaction_id and id <> ord.id)
     or exists (select 1 from business_boosts where apple_transaction_id = p_transaction_id) then
    raise exception 'transaction_used';
  end if;

  v_fact := private.appstore_check(p_transaction_id);
  v_product := coalesce(v_fact->>'product_id', p_product_id);
  if v_fact is not null and nullif(v_fact->>'revoked_at','') is not null then raise exception 'refunded'; end if;
  if ord.product_id is distinct from v_product then raise exception 'product_mismatch'; end if;

  update business_orders
     set paid = true, paid_at = now(),
         apple_transaction_id = p_transaction_id,
         apple_original_transaction_id = coalesce(nullif(v_fact->>'original_transaction_id',''), p_original_transaction_id),
         apple_jws = p_jws
   where id = ord.id;
  perform private.business_order_sync(ord.id);
end $$;

create or replace function public.business_boost_paid(
  p_boost uuid, p_transaction_id text, p_product_id text,
  p_original_transaction_id text default null, p_jws text default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare bo public.business_boosts; b public.businesses; v_fact jsonb; v_product text;
begin
  select * into bo from business_boosts where id = p_boost;
  if bo.id is null then raise exception 'no_boost'; end if;
  b := private.business_for_owner(bo.business_id, false);
  if bo.status in ('live','done') and bo.apple_transaction_id = p_transaction_id then return; end if;
  if bo.status <> 'pending' then raise exception 'boost_not_pending'; end if;
  if exists (select 1 from business_boosts where apple_transaction_id = p_transaction_id and id <> bo.id)
     or exists (select 1 from business_orders where apple_transaction_id = p_transaction_id) then
    raise exception 'transaction_used';
  end if;

  v_fact := private.appstore_check(p_transaction_id);
  v_product := coalesce(v_fact->>'product_id', p_product_id);
  if v_fact is not null and nullif(v_fact->>'revoked_at','') is not null then raise exception 'refunded'; end if;
  if bo.product_id <> v_product then raise exception 'product_mismatch'; end if;

  update business_boosts
     set status = 'live', paid_at = now(), apple_transaction_id = p_transaction_id,
         apple_original_transaction_id = coalesce(nullif(v_fact->>'original_transaction_id',''), p_original_transaction_id),
         apple_jws = p_jws
   where id = bo.id;
end $$;

-- ── The webhook's write path ────────────────────────────────────────────────
-- Everything here already came from Apple; appstore-notify re-asked Apple
-- before calling us, so p_fact is Apple's word, not the caller's.
create or replace function public.appstore_apply(
  p_fact jsonb, p_status integer, p_paid boolean, p_notification text)
returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_biz uuid; v_tier text; v_product text; v_orig text; v_txn text; v_expires timestamptz;
begin
  v_product := p_fact->>'product_id';
  v_orig    := nullif(p_fact->>'original_transaction_id', '');
  v_txn     := nullif(p_fact->>'transaction_id', '');
  v_expires := nullif(p_fact->>'expires_at', '')::timestamptz;

  -- Which bar? The app stamps the business id into appAccountToken; fall back
  -- to whatever we recorded when the subscription was first bought.
  begin v_biz := nullif(p_fact->>'app_account_token', '')::uuid; exception when others then v_biz := null; end;
  if v_biz is not null and not exists (select 1 from businesses where id = v_biz) then v_biz := null; end if;
  if v_biz is null and v_orig is not null then
    select id into v_biz from businesses where apple_original_transaction_id = v_orig limit 1;
  end if;
  if v_biz is null and v_orig is not null then
    select business_id into v_biz from business_subscription_log
     where apple_original_transaction_id = v_orig order by created_at desc limit 1;
  end if;

  -- A refunded consumable stops doing what it paid for.
  if v_product like 'sejdel.biz.boost.%' or v_product like 'sejdel.biz.card.%'
     or v_product like 'sejdel.biz.push.%' then
    if not p_paid and v_txn is not null then
      update business_boosts set status = 'cancelled'
       where apple_transaction_id = v_txn and status in ('pending','live');
      update business_orders set status = 'cancelled', paid = false
       where apple_transaction_id = v_txn and status <> 'cancelled';
      perform private.business_order_sync(o.id) from business_orders o where o.apple_transaction_id = v_txn;
    end if;
    return jsonb_build_object('kind', 'consumable', 'paid', p_paid, 'business', v_biz);
  end if;

  v_tier := case v_product
              when 'sejdel.biz.business.monthly' then 'business'
              when 'sejdel.biz.plus.monthly'     then 'plus'
              else null end;
  if v_tier is null then return jsonb_build_object('ignored', 'not_our_product'); end if;
  if v_biz is null then return jsonb_build_object('ignored', 'no_business'); end if;

  insert into business_subscription_log (business_id, product_id, tier, expires_at,
                                         apple_original_transaction_id, apple_transaction_id, apple_jws)
  values (v_biz, v_product, case when p_paid then v_tier else 'none' end, v_expires, v_orig, v_txn,
          'notification:' || coalesce(p_notification, ''));

  if not p_paid or (v_expires is not null and v_expires <= now()) then
    if private.biz_tier(v_biz) <> 'none' then perform private.business_revert(v_biz); end if;
    return jsonb_build_object('kind', 'subscription', 'tier', 'none', 'business', v_biz, 'reverted', true);
  end if;

  -- An ended bar is not brought back from here: reverting also took its owner
  -- out of business mode, and only claiming the bar again puts them back.
  if (select status from businesses where id = v_biz) <> 'approved' then
    return jsonb_build_object('ignored', 'business_ended', 'business', v_biz);
  end if;

  update businesses
     set tier = v_tier, tier_product_id = v_product, tier_expires_at = v_expires,
         apple_original_transaction_id = coalesce(v_orig, apple_original_transaction_id),
         tier_synced_at = now()
   where id = v_biz;
  perform private.business_sync_presence(v_biz);
  return jsonb_build_object('kind', 'subscription', 'tier', v_tier, 'business', v_biz, 'expires_at', v_expires);
end $$;

revoke all on function public.appstore_apply(jsonb, integer, boolean, text) from public, anon, authenticated;
grant execute on function public.appstore_apply(jsonb, integer, boolean, text) to service_role;
