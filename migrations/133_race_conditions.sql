-- 133: close the read-then-write windows.
--
-- Every fix here is one of two shapes. Either the read and the write
-- become ONE statement (an UPDATE whose SET expression reads the row it
-- changes, or an INSERT ... ON CONFLICT), so Postgres serialises concurrent
-- callers on the row lock and each sees the other's committed value. Or the
-- row that the decision depends on is locked with FOR UPDATE at the top of
-- the function, so the check-then-act inside runs one caller at a time.
--
-- Already safe and left alone: rate_limit_hit, bump_campaign_stats,
-- join_session_by_code, set_like, block_user, follow_business,
-- register_device_token (all INSERT ... ON CONFLICT), claim_sponsored_card
-- and sun_venue_budget_take (FOR UPDATE [SKIP LOCKED]), speakeasy_apply
-- (FOR UPDATE on the match row), set_event_ghosts (host-only, one writer).

------------------------------------------------------------------------
-- 1. Session guests. The whole roster used to be rewritten from the phone
--    (set_session_ghosts): two members adding a guest, or logging a guest's
--    drink, inside the same poll window lost one of the edits. Four
--    single-UPDATE operations keyed by guest id replace that. The old RPC
--    stays for builds that still call it.
------------------------------------------------------------------------

create or replace function public.session_ghost_upsert(p_session_id uuid, p_ghost jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_session_member(p_session_id) then raise exception 'not a session member'; end if;
  if coalesce(p_ghost->>'id', '') = '' then raise exception 'ghost id required'; end if;
  update sessions s
     set ghosts = coalesce((
           select jsonb_agg(case when lower(g.value->>'id') = lower(p_ghost->>'id') then p_ghost else g.value end
                            order by g.ord)
             from jsonb_array_elements(coalesce(s.ghosts, '[]'::jsonb)) with ordinality as g(value, ord)
         ), '[]'::jsonb)
         || case when exists (select 1 from jsonb_array_elements(coalesce(s.ghosts, '[]'::jsonb)) g
                               where lower(g->>'id') = lower(p_ghost->>'id'))
                 then '[]'::jsonb else jsonb_build_array(p_ghost) end
   where s.id = p_session_id;
end $$;

create or replace function public.session_ghost_remove(p_session_id uuid, p_ghost_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_session_member(p_session_id) then raise exception 'not a session member'; end if;
  update sessions s
     set ghosts = coalesce((
           select jsonb_agg(g.value order by g.ord)
             from jsonb_array_elements(coalesce(s.ghosts, '[]'::jsonb)) with ordinality as g(value, ord)
            where lower(g.value->>'id') <> lower(p_ghost_id::text)
         ), '[]'::jsonb)
   where s.id = p_session_id;
end $$;

create or replace function public.session_ghost_drink_add(p_session_id uuid, p_ghost_id uuid, p_drink jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_session_member(p_session_id) then raise exception 'not a session member'; end if;
  if coalesce(p_drink->>'id', '') = '' then raise exception 'drink id required'; end if;
  update sessions s
     set ghosts = coalesce((
           select jsonb_agg(
                    case when lower(g.value->>'id') = lower(p_ghost_id::text)
                          and not exists (select 1 from jsonb_array_elements(coalesce(g.value->'drinks', '[]'::jsonb)) d
                                           where lower(d->>'id') = lower(p_drink->>'id'))
                         then jsonb_set(g.value, '{drinks}',
                                        coalesce(g.value->'drinks', '[]'::jsonb) || jsonb_build_array(p_drink))
                         else g.value end
                    order by g.ord)
             from jsonb_array_elements(coalesce(s.ghosts, '[]'::jsonb)) with ordinality as g(value, ord)
         ), '[]'::jsonb)
   where s.id = p_session_id;
end $$;

create or replace function public.session_ghost_drink_remove(p_session_id uuid, p_ghost_id uuid, p_drink_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not is_session_member(p_session_id) then raise exception 'not a session member'; end if;
  update sessions s
     set ghosts = coalesce((
           select jsonb_agg(
                    case when lower(g.value->>'id') = lower(p_ghost_id::text)
                         then jsonb_set(g.value, '{drinks}', coalesce((
                                select jsonb_agg(d.value order by d.ord)
                                  from jsonb_array_elements(coalesce(g.value->'drinks', '[]'::jsonb)) with ordinality as d(value, ord)
                                 where lower(d.value->>'id') <> lower(p_drink_id::text)
                              ), '[]'::jsonb))
                         else g.value end
                    order by g.ord)
             from jsonb_array_elements(coalesce(s.ghosts, '[]'::jsonb)) with ordinality as g(value, ord)
         ), '[]'::jsonb)
   where s.id = p_session_id;
end $$;

revoke execute on function public.session_ghost_upsert(uuid, jsonb) from anon;
revoke execute on function public.session_ghost_remove(uuid, uuid) from anon;
revoke execute on function public.session_ghost_drink_add(uuid, uuid, jsonb) from anon;
revoke execute on function public.session_ghost_drink_remove(uuid, uuid, uuid) from anon;
grant execute on function public.session_ghost_upsert(uuid, jsonb) to authenticated;
grant execute on function public.session_ghost_remove(uuid, uuid) to authenticated;
grant execute on function public.session_ghost_drink_add(uuid, uuid, jsonb) to authenticated;
grant execute on function public.session_ghost_drink_remove(uuid, uuid, uuid) to authenticated;

------------------------------------------------------------------------
-- 2. QR token: two concurrent calls each generated a token and the second
--    overwrote the first, so a QR printed from the first was dead on
--    arrival. One UPDATE that keeps an existing token.
------------------------------------------------------------------------

create or replace function public.ensure_qr_token(p_venue uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  loop
    begin
      update venues
         set qr_token = coalesce(qr_token, (
               select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', (random() * 31)::int + 1, 1), '')
                 from generate_series(1, 10)))
       where id = p_venue
       returning qr_token into v_token;
      return v_token;
    exception when unique_violation then
      -- generated token collided with another venue's: roll the dice again
      null;
    end;
  end loop;
end $$;

------------------------------------------------------------------------
-- 3. Find-or-create venue, shared by every path that resolves a venue by
--    external id or by name + position. Concurrent first submissions for a
--    new bar used to create it twice. The advisory lock serialises callers
--    on the venue's identity; the external-id insert is an upsert.
------------------------------------------------------------------------

create or replace function private.venue_find_or_create(
  p_name text, p_address text, p_city text, p_lat double precision, p_lon double precision,
  p_external_id text, p_country text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_venue uuid; v_key text;
begin
  v_key := coalesce('ext:' || p_external_id,
                    'geo:' || lower(coalesce(p_name, '')) || ':' || round(p_lat::numeric, 3) || ':' || round(p_lon::numeric, 3));
  perform pg_advisory_xact_lock(hashtext('venue:' || v_key));
  if p_external_id is not null then
    select id into v_venue from venues where external_id = p_external_id limit 1;
  end if;
  if v_venue is null and coalesce(p_name, '') <> '' then
    select id into v_venue from venues
     where lower(name) = lower(p_name) and abs(lat - p_lat) < 0.001 and abs(lon - p_lon) < 0.001 limit 1;
  end if;
  if v_venue is null then
    if coalesce(p_name, '') = '' then raise exception 'venue_required'; end if;
    insert into venues (name, address, city, lat, lon, source, external_id, country)
    values (p_name, p_address, p_city, p_lat, p_lon, 'user', p_external_id, p_country)
    on conflict (source, external_id) where external_id is not null
      do update set updated_at = now()
    returning id into v_venue;
  end if;
  return v_venue;
end $$;

create or replace function public.submit_beer_price(p_name text, p_lat double precision, p_lon double precision, p_external_id text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_price numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_serving text DEFAULT '40'::text, p_currency text DEFAULT 'SEK'::text)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare
  v_venue uuid; v_id uuid;
  v_serving  text := coalesce(p_serving, '40');
  v_currency text := upper(coalesce(nullif(p_currency,''), 'SEK'));
  c_min numeric; c_max numeric;
begin
  if auth.uid() is null then raise exception 'not_authed'; end if;
  if v_serving not in ('25','33','40','47.3','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;

  c_min := case v_currency when 'SEK' then 10 when 'NOK' then 15 when 'DKK' then 8
                           when 'EUR' then 2 when 'GBP' then 2 when 'USD' then 2
                           when 'JPY' then 150 else 1 end;
  c_max := case v_currency when 'SEK' then 300 when 'NOK' then 400 when 'DKK' then 250
                           when 'EUR' then 30 when 'GBP' then 30 when 'USD' then 30
                           when 'JPY' then 3000 else 100000 end;
  if p_price is null or p_price < c_min or p_price > c_max then raise exception 'implausible_price'; end if;

  v_venue := private.venue_find_or_create(p_name, p_address, p_city, p_lat, p_lon, p_external_id);

  delete from beer_prices where venue_id = v_venue and user_id = auth.uid() and serving = v_serving;
  insert into beer_prices (venue_id, user_id, price_sek, serving, currency, note)
  values (v_venue, auth.uid(), p_price, v_serving, v_currency, nullif(p_note,''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.submit_beer_price_web(p_name text, p_lat double precision, p_lon double precision, p_external_id text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_price numeric DEFAULT NULL::numeric, p_serving text DEFAULT '40'::text, p_currency text DEFAULT 'SEK'::text)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare
  v_venue uuid; v_id uuid; v_recent int;
  v_serving  text := coalesce(p_serving,'40');
  v_currency text := upper(coalesce(nullif(p_currency,''),'SEK'));
  v_ip text := request_ip();
  c_min numeric; c_max numeric;
begin
  if not rate_limit_hit('web_submit_ip_burst', v_ip, 3, '1 minute') then
    raise exception 'rate_limited';
  end if;
  if not rate_limit_hit('web_submit_ip', v_ip, 8, '1 hour') then
    raise exception 'rate_limited';
  end if;

  if coalesce(p_name,'') = '' then raise exception 'name_required'; end if;
  if v_serving not in ('25','33','40','47.3','50','pint') then raise exception 'bad_serving'; end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'bad_currency'; end if;
  if p_lat is null or p_lon is null or abs(p_lat) > 90 or abs(p_lon) > 180
     or (abs(p_lat) < 0.01 and abs(p_lon) < 0.01) then raise exception 'bad_location'; end if;
  select count(*) into v_recent from beer_prices
    where source = 'web' and created_at > now() - interval '1 minute';
  if v_recent >= 30 then raise exception 'rate_limited'; end if;

  c_min := case v_currency when 'SEK' then 10 when 'NOK' then 15 when 'DKK' then 8
                           when 'EUR' then 2 when 'GBP' then 2 when 'USD' then 2
                           when 'JPY' then 150 else 1 end;
  c_max := case v_currency when 'SEK' then 300 when 'NOK' then 400 when 'DKK' then 250
                           when 'EUR' then 30 when 'GBP' then 30 when 'USD' then 30
                           when 'JPY' then 3000 else 100000 end;
  if p_price is null or p_price < c_min or p_price > c_max then raise exception 'implausible_price'; end if;

  v_venue := private.venue_find_or_create(p_name, p_address, p_city, p_lat, p_lon, p_external_id);

  insert into beer_prices (venue_id, user_id, price_sek, serving, currency, note, source)
  values (v_venue, null, p_price, v_serving, v_currency, null, 'web')
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_create_offer(p_name text, p_address text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_lat double precision DEFAULT 0, p_lon double precision DEFAULT 0, p_external_id text DEFAULT NULL::text, p_kind text DEFAULT 'price'::text, p_title text DEFAULT ''::text, p_description text DEFAULT NULL::text, p_fine_print text DEFAULT NULL::text, p_redeem text DEFAULT 'show'::text, p_code text DEFAULT NULL::text, p_starts_at timestamp with time zone DEFAULT now(), p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_active_days integer[] DEFAULT NULL::integer[], p_start_minute integer DEFAULT NULL::integer, p_end_minute integer DEFAULT NULL::integer, p_placement text DEFAULT 'pin'::text, p_image_url text DEFAULT NULL::text, p_billboard_image_url text DEFAULT NULL::text, p_interstitial boolean DEFAULT false, p_show_on_valid_only boolean DEFAULT false)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare v_venue uuid; v_offer uuid;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if p_placement not in ('pin','poster','billboard') then raise exception 'bad_placement'; end if;
  if coalesce(p_title,'') = '' then raise exception 'title_required'; end if;

  v_venue := private.venue_find_or_create(p_name, p_address, p_city, p_lat, p_lon, p_external_id);

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

------------------------------------------------------------------------
-- 4. Business flows. Each checks "is there already a pending X" or "how
--    many live X" and then inserts. Locking the business row (or the post,
--    the order, the boost) turns that into one caller at a time.
------------------------------------------------------------------------

create or replace function public.business_register(p_business_name text, p_contact_email text, p_contact_phone text DEFAULT NULL::text, p_org_number text DEFAULT NULL::text, p_venue_external_id text DEFAULT NULL::text, p_venue_name text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_lat double precision DEFAULT 0, p_lon double precision DEFAULT 0, p_country text DEFAULT NULL::text)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare v_venue uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  -- One registration per owner at a time: a double tap used to pass the
  -- "already a business" check twice.
  perform 1 from profiles where id = auth.uid() for update;
  if coalesce(trim(p_business_name),'') = '' then raise exception 'name_required'; end if;
  if coalesce(p_contact_email,'') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email_invalid'; end if;
  if exists (select 1 from businesses where owner_id = auth.uid() and status in ('pending','approved','suspended')) then
    raise exception 'already_business';
  end if;

  if p_venue_external_id is null and coalesce(p_venue_name,'') = '' then raise exception 'venue_required'; end if;
  v_venue := private.venue_find_or_create(p_venue_name, p_address, p_city, p_lat, p_lon, p_venue_external_id, p_country);

  if exists (select 1 from businesses where venue_id = v_venue and status in ('pending','approved','suspended')) then
    raise exception 'venue_taken';
  end if;

  insert into businesses (owner_id, venue_id, name, org_number, contact_email, contact_phone)
  values (auth.uid(), v_venue, trim(p_business_name), nullif(trim(coalesce(p_org_number,'')),''),
          lower(trim(p_contact_email)), nullif(trim(coalesce(p_contact_phone,'')),''))
  returning id into v_id;
  perform private.business_takeover(v_id);
  return v_id;
end $$;

create or replace function public.business_create_boost(p_post uuid, p_product_id text)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare p public.business_posts; b public.businesses; prod public.business_products; v_boost uuid;
begin
  select * into p from business_posts where id = p_post and deleted_at is null for update;
  if p.id is null then raise exception 'no_post'; end if;
  b := private.business_for_owner(p.business_id, true);
  if private.biz_tier(b.id) <> 'plus' then raise exception 'plus_required'; end if;
  select * into prod from business_products where product_id = p_product_id and kind = 'boost';
  if prod.product_id is null then raise exception 'no_product'; end if;
  if exists (select 1 from business_boosts where post_id = p.id and status in ('pending','live')) then
    raise exception 'boost_pending';
  end if;
  insert into business_boosts (business_id, post_id, product_id, goal_views)
  values (b.id, p.id, prod.product_id, prod.quantity)
  returning id into v_boost;
  return v_boost;
end $$;

create or replace function public.business_create_deal(p_business uuid, p_kind text, p_title text, p_description text DEFAULT NULL::text, p_fine_print text DEFAULT NULL::text, p_starts_at timestamp with time zone DEFAULT now(), p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_active_days integer[] DEFAULT NULL::integer[], p_start_minute integer DEFAULT NULL::integer, p_end_minute integer DEFAULT NULL::integer, p_image_url text DEFAULT NULL::text, p_show_on_valid_only boolean DEFAULT false)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare b public.businesses; v public.venues; v_tier text; v_offer uuid; v_days integer; v_max integer;
begin
  b := private.business_for_owner(p_business, true);
  perform 1 from businesses where id = b.id for update;
  v_tier := private.biz_tier(b.id);
  if v_tier = 'none' then raise exception 'subscription_required'; end if;
  select * into v from venues where id = b.venue_id;
  if p_kind not in ('price','happy_hour','free_entry','bundle','event') then raise exception 'bad_kind'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception 'title_required'; end if;
  if length(p_title) > 60 or length(coalesce(p_description,'')) > 200 or length(coalesce(p_fine_print,'')) > 120 then
    raise exception 'too_long';
  end if;
  if p_ends_at is null then raise exception 'end_required'; end if;
  if p_ends_at <= p_starts_at then raise exception 'window_invalid'; end if;
  if p_ends_at < now() then raise exception 'window_past'; end if;
  v_days := greatest(1, round(extract(epoch from (p_ends_at - p_starts_at)) / 86400.0)::int);
  if v_days > private.biz_limit('campaign_max_days') then raise exception 'too_long_window'; end if;
  v_max := case when v_tier = 'plus' then private.biz_limit('max_live_campaigns') else private.biz_limit('max_live_campaigns_basic') end;
  if (select count(*) from venue_offers o where o.business_id = b.id and o.is_active
        and (o.ends_at is null or o.ends_at > now())) >= v_max then
    raise exception 'too_many_campaigns';
  end if;
  insert into venue_offers (venue_id, kind, title, description, fine_print, redeem, code,
                            starts_at, ends_at, active_days, start_minute, end_minute,
                            is_active, approved, placement, image_url, billboard_image_url,
                            interstitial, show_on_valid_only, business_id)
  values (v.id, p_kind, trim(p_title), nullif(trim(coalesce(p_description,'')),''),
          nullif(trim(coalesce(p_fine_print,'')),''), 'show', null,
          p_starts_at, p_ends_at, p_active_days, p_start_minute, p_end_minute,
          true, true,
          case when v_tier = 'plus' and p_image_url is not null then 'poster' else 'pin' end,
          p_image_url, null, false, coalesce(p_show_on_valid_only, false), b.id)
  returning id into v_offer;
  return v_offer;
end $$;

create or replace function public.business_create_event(p_business uuid, p_title text, p_starts_at timestamp with time zone, p_image_url text DEFAULT NULL::text, p_image_ratio real DEFAULT 1)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare b public.businesses; v_id uuid; v_recent boolean; v_when text; v_tz text;
begin
  b := private.business_for_owner(p_business, true);
  perform 1 from businesses where id = b.id for update;
  if private.biz_tier(b.id) <> 'plus' then raise exception 'plus_required'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'title_required'; end if;
  if length(p_title) > 60 then raise exception 'too_long'; end if;
  if p_starts_at < now() then raise exception 'window_past'; end if;
  select exists (select 1 from business_events where business_id = b.id and created_at > now() - interval '24 hours') into v_recent;
  insert into business_events (business_id, title, starts_at, image_url, image_ratio)
  values (b.id, trim(p_title), p_starts_at, p_image_url, least(1.91, greatest(0.8, coalesce(p_image_ratio, 1))))
  returning id into v_id;
  if not v_recent then
    select coalesce(v.time_zone, 'Europe/Stockholm') into v_tz from venues v where v.id = b.venue_id;
    v_when := to_char(p_starts_at at time zone v_tz, 'Dy DD Mon HH24:MI');
    perform private.notify_push(f.user_id, b.name, trim(p_title) || ' · ' || v_when,
              jsonb_build_object('type', 'business_event', 'business_id', b.id, 'event_id', v_id))
       from business_follows f where f.business_id = b.id;
  end if;
  return v_id;
end $$;

create or replace function public.business_request_card(p_business uuid, p_offer uuid, p_audience_cap integer)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare b public.businesses; o public.venue_offers; prod public.business_products; v_card uuid; v_order uuid; v_days integer;
begin
  b := private.business_for_owner(p_business, true);
  perform 1 from businesses where id = b.id for update;
  if private.biz_tier(b.id) <> 'plus' then raise exception 'plus_required'; end if;
  select * into o from venue_offers where id = p_offer and business_id = b.id and is_active;
  if o.id is null then raise exception 'no_offer'; end if;
  if o.image_url is null then raise exception 'image_required'; end if;
  prod := private.biz_product('card', p_audience_cap);
  if prod.product_id is null then raise exception 'cap_range'; end if;
  if exists (select 1 from business_cards where business_id = b.id and status in ('pending','live')) then
    raise exception 'card_pending';
  end if;
  v_days := private.biz_limit('card_window_days');
  insert into business_cards (business_id, offer_id, audience_cap, ends_at)
  values (b.id, o.id, p_audience_cap,
          least(coalesce(o.ends_at, now() + make_interval(days => v_days)), now() + make_interval(days => v_days)))
  returning id into v_card;
  insert into business_orders (business_id, kind, card_id, amount_sek, detail, product_id, quantity)
  values (b.id, 'card', v_card, prod.amount_sek, format('App-open card · %s people · "%s"', p_audience_cap, o.title),
          prod.product_id, 1)
  returning id into v_order;
  return v_order;
end $$;

create or replace function public.business_request_push(p_business uuid, p_offer uuid, p_title text, p_body text, p_audience_cap integer, p_send_at timestamp with time zone)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare
  b public.businesses; o public.venue_offers; v public.venues; prod public.business_products; v_push uuid; v_order uuid;
  v_last timestamptz; v_hour integer; v_tz text; v_cool integer;
begin
  b := private.business_for_owner(p_business, true);
  perform 1 from businesses where id = b.id for update;
  if private.biz_tier(b.id) <> 'plus' then raise exception 'plus_required'; end if;
  select * into v from venues where id = b.venue_id;
  v_tz := coalesce(v.time_zone, 'Europe/Stockholm');
  select * into o from venue_offers where id = p_offer and business_id = b.id and is_active;
  if o.id is null then raise exception 'no_offer'; end if;
  if coalesce(trim(p_title),'') = '' or coalesce(trim(p_body),'') = '' then raise exception 'empty'; end if;
  if length(p_title) > 40 or length(p_body) > 120 then raise exception 'too_long'; end if;
  prod := private.biz_product('push', p_audience_cap);
  if prod.product_id is null then raise exception 'cap_range'; end if;
  if p_send_at < now() - interval '5 minutes' or p_send_at > now() + interval '30 days' then
    raise exception 'send_at_range';
  end if;
  v_hour := extract(hour from (p_send_at at time zone v_tz))::int;
  if v_hour >= private.biz_limit('quiet_start_hour') and v_hour < private.biz_limit('quiet_end_hour') then
    raise exception 'quiet_hours';
  end if;
  if exists (select 1 from business_pushes where business_id = b.id and status in ('pending','approved')) then
    raise exception 'push_pending';
  end if;
  v_cool := private.biz_limit('push_cooldown_days');
  select max(sent_at) into v_last from business_pushes where business_id = b.id and status = 'sent';
  if v_last is not null and v_last > now() - make_interval(days => v_cool) then
    raise exception 'push_cooldown:%', to_char((v_last + make_interval(days => v_cool)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  insert into business_pushes (business_id, offer_id, title, body, audience_cap, send_at)
  values (b.id, o.id, trim(p_title), trim(p_body), p_audience_cap, p_send_at)
  returning id into v_push;
  insert into business_orders (business_id, kind, push_id, amount_sek, detail, product_id, quantity)
  values (b.id, 'push', v_push, prod.amount_sek,
          format('Push · up to %s people · %s', p_audience_cap, to_char(p_send_at at time zone v_tz, 'Dy DD Mon HH24:MI')),
          prod.product_id, 1)
  returning id into v_order;
  return v_order;
end $$;

------------------------------------------------------------------------
-- 5. Money. Mark-paid, boost-paid, the order sync and the App Store
--    notification handler all read a row, decide, and write it. Lock the
--    row they decide on.
------------------------------------------------------------------------

create or replace function private.business_order_sync(p_order uuid)
returns void language plpgsql security definer set search_path = public, private as $$
declare ord public.business_orders; v_go boolean;
begin
  select * into ord from business_orders where id = p_order for update;
  if ord.id is null then return; end if;
  v_go := ord.status = 'approved' and ord.paid;
  if ord.offer_id is not null then
    update venue_offers
       set approved = v_go, is_active = ord.status not in ('rejected','cancelled')
     where id = ord.offer_id;
  end if;
  if ord.card_id is not null then
    update business_cards
       set status = case
             when ord.status in ('rejected') then 'rejected'
             when ord.status = 'cancelled' then 'cancelled'
             when v_go and delivered >= audience_cap then 'done'
             when v_go then 'live'
             else 'pending' end,
           starts_at = case when v_go and status = 'pending' then now() else starts_at end,
           ends_at   = case when v_go and status = 'pending'
                            then now() + make_interval(days => private.biz_limit('card_window_days'))
                            else ends_at end
     where id = ord.card_id;
  end if;
  if ord.push_id is not null then
    update business_pushes
       set status = case
             when status = 'sent' then 'sent'
             when ord.status = 'rejected' then 'rejected'
             when ord.status = 'cancelled' then 'cancelled'
             when v_go then 'approved'
             else 'pending' end
     where id = ord.push_id;
  end if;
end $$;

create or replace function public.business_mark_paid(p_order uuid, p_transaction_id text, p_product_id text, p_original_transaction_id text DEFAULT NULL::text, p_jws text DEFAULT NULL::text)
returns void language plpgsql security definer set search_path = public, private as $$
declare ord public.business_orders; b public.businesses; v_fact jsonb; v_product text;
begin
  select * into ord from business_orders where id = p_order for update;
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

create or replace function public.business_boost_paid(p_boost uuid, p_transaction_id text, p_product_id text, p_original_transaction_id text DEFAULT NULL::text, p_jws text DEFAULT NULL::text)
returns void language plpgsql security definer set search_path = public, private as $$
declare bo public.business_boosts; b public.businesses; v_fact jsonb; v_product text;
begin
  select * into bo from business_boosts where id = p_boost for update;
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

create or replace function public.appstore_apply(p_fact jsonb, p_status integer, p_paid boolean, p_notification text)
returns jsonb language plpgsql security definer set search_path = public, private as $$
declare v_biz uuid; v_tier text; v_product text; v_orig text; v_txn text; v_expires timestamptz;
begin
  v_product := p_fact->>'product_id';
  v_orig    := nullif(p_fact->>'original_transaction_id', '');
  v_txn     := nullif(p_fact->>'transaction_id', '');
  v_expires := nullif(p_fact->>'expires_at', '')::timestamptz;

  begin v_biz := nullif(p_fact->>'app_account_token', '')::uuid; exception when others then v_biz := null; end;
  if v_biz is not null and not exists (select 1 from businesses where id = v_biz) then v_biz := null; end if;
  if v_biz is null and v_orig is not null then
    select id into v_biz from businesses where apple_original_transaction_id = v_orig limit 1;
  end if;
  if v_biz is null and v_orig is not null then
    select business_id into v_biz from business_subscription_log
     where apple_original_transaction_id = v_orig order by created_at desc limit 1;
  end if;
  -- Apple retries and sends several notifications per event; one at a
  -- time per business so revert and renew can't interleave.
  if v_biz is not null then perform 1 from businesses where id = v_biz for update; end if;

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

------------------------------------------------------------------------
-- 6. Guest list request: a double tap passed "already requested" twice and
--    sent the bar two DMs. One request per user at a time.
------------------------------------------------------------------------

create or replace function public.list_request_send(p_business uuid, p_full_name text, p_instagram text, p_plus integer, p_night date)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare v_me uuid := auth.uid(); v_account uuid; v_name text; v_insta text; v_id uuid; b businesses; v_flag text; v_status text := 'pending';
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  perform 1 from profiles where id = v_me for update;
  select * into b from businesses where id = p_business and status = 'approved';
  if b.id is null or private.biz_tier(b.id) = 'none' then raise exception 'not_on_sejdel'; end if;
  select id into v_account from profiles where business_id = b.id limit 1;
  if v_account is null then raise exception 'no_account'; end if;
  if v_account = v_me then raise exception 'own_bar'; end if;
  v_name := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  if char_length(v_name) < 2 then raise exception 'name_required'; end if;

  -- Instagram is optional. A blank handle stores NULL; anything supplied is
  -- still normalised and must look like a real handle, so the bar never gets
  -- a half-typed URL.
  v_insta := lower(btrim(coalesce(p_instagram, '')));
  v_insta := regexp_replace(v_insta, '^(https?://)?(www\.)?instagram\.com/', '');
  v_insta := regexp_replace(v_insta, '^@+', '');
  v_insta := regexp_replace(v_insta, '[/?#].*$', '');
  if v_insta = '' then
    v_insta := null;
  elsif v_insta !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'instagram_invalid';
  end if;

  if p_plus is null or p_plus < 0 or p_plus > 50 then raise exception 'bad_party'; end if;
  if p_night is null or p_night < current_date then raise exception 'bad_night'; end if;
  if not (extract(isodow from p_night)::smallint = any (b.list_days)) then raise exception 'closed_night'; end if;
  if exists (select 1 from list_requests r where r.business_id = b.id and r.user_id = v_me and r.night = p_night and r.status = 'pending') then
    raise exception 'already_requested';
  end if;
  if private.biz_tier(b.id) = 'plus' then
    select flag into v_flag from list_guest_flags where business_id = b.id and user_id = v_me;
    v_status := case v_flag when 'favorite' then 'approved' when 'blocked' then 'declined' else 'pending' end;
  end if;
  insert into list_requests (business_id, user_id, full_name, instagram, plus_count, night, status, decided_at)
  values (b.id, v_me, v_name, v_insta, p_plus, p_night, v_status, case when v_status = 'pending' then null else now() end)
  returning id into v_id;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_me, v_account, 'list_request',
          format('🎟 Get on the list · %s · %s +%s%s', to_char(p_night, 'Dy FMDD Mon'), v_name, p_plus,
                 case when v_insta is null then '' else ' · @' || v_insta end), v_id);
  if v_status <> 'pending' then perform private.list_request_reply(v_id); end if;
  return v_id;
end $$;

------------------------------------------------------------------------
-- 7. Deal pushes: the weekly cap was counted, then the log row inserted.
--    Lock the venue so two admins can't both squeeze under the cap.
------------------------------------------------------------------------

create or replace function public.send_venue_push(p_offer_id uuid, p_title text, p_body text)
returns integer language plpgsql security definer set search_path = public, private as $$
declare
  v_venue uuid; v_lat double precision; v_lon double precision;
  v_recent int; v_hour int; v_count int := 0;
  c_radius_m constant double precision := 25000;
  c_fresh    constant interval := interval '30 days';
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if coalesce(p_title,'') = '' or coalesce(p_body,'') = '' then raise exception 'empty'; end if;

  select venue_id into v_venue from venue_offers where id = p_offer_id;
  if v_venue is null then raise exception 'no_offer'; end if;
  select lat, lon into v_lat, v_lon from venues where id = v_venue for update;

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

------------------------------------------------------------------------
-- 8. Timed jobs. pg_cron starts a new run on schedule even if the last one
--    is still going; the event job could then create a second live session
--    for one event, and the weekend push could go out twice.
------------------------------------------------------------------------

create or replace function public.run_event_live_lifecycle()
returns void language plpgsql security definer set search_path = public, private as $$
declare
  ev record;
  v_session uuid;
  v_code text;
  v_event_end timestamptz;
  v_last_activity timestamptz;
  v_session_active boolean;
begin
  for ev in
    select * from events e
    where e.auto_live
      and e.live_session_id is null
      and e.starts_at <= now()
      and e.starts_at > now() - interval '12 hours'
    for update skip locked
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    insert into sessions (host_id, join_code, active_plan, active_live)
    values (ev.host_id, v_code, false, true)
    returning id into v_session;

    if ev.location is not null and ev.location_kind = 'venue' then
      update sessions set live_venue = ev.location where id = v_session;
    elsif ev.location is not null and ev.location_kind = 'spot' then
      update sessions set live_loose_spot = ev.location where id = v_session;
    end if;

    insert into session_members (session_id, profile_id, in_plan, in_live)
    select v_session, m.profile_id, false, true
    from event_members m
    where m.event_id = ev.id and m.status = 'going';

    update events
       set live_session_id = v_session, live_started_at = now()
     where id = ev.id;

    perform private.notify_push(
      m.profile_id,
      '🔴 ' || ev.title || ' just went live',
      'Your group sesh is running — open sesh and start logging.',
      jsonb_build_object('type', 'event_live', 'event_id', ev.id)
    )
    from event_members m
    where m.event_id = ev.id and m.status = 'going';
  end loop;

  for ev in
    select * from events e
    where e.live_session_id is not null
      and e.live_ended_at is null
    for update skip locked
  loop
    select s.active_live into v_session_active
      from sessions s where s.id = ev.live_session_id;

    if v_session_active is distinct from true then
      update events set live_ended_at = now() where id = ev.id;
      continue;
    end if;

    v_event_end := ev.starts_at
      + make_interval(days => greatest(ev.nights, 1) - 1)
      + (ev.duration_hours * interval '1 hour');

    select max(d.created_at) into v_last_activity
      from session_drinks d
     where d.session_id = ev.live_session_id;
    v_last_activity := greatest(
      coalesce(v_last_activity, ev.live_started_at),
      ev.live_started_at
    );

    if now() >= v_event_end and now() >= v_last_activity + interval '6 hours' then
      update sessions set active_live = false where id = ev.live_session_id;
      update events set live_ended_at = now() where id = ev.id;
    end if;
  end loop;
exception when others then
  return;
end $$;

create or replace function private.run_weekend_push()
returns integer language plpgsql security definer set search_path = public, private as $$
declare r record; v_local timestamp; v_week date; v_n integer := 0; v_title text; v_body text;
begin
  for r in
    select p.id,
           coalesce((select t.time_zone from device_tokens t
                      where t.user_id = p.id and t.time_zone is not null
                      order by t.updated_at desc limit 1), 'Europe/Stockholm') as tz
      from profiles p
     where p.weekend_push_opt_in and p.business_id is null
       and exists (select 1 from device_tokens t where t.user_id = p.id)
  loop
    v_local := now() at time zone r.tz;
    if extract(dow from v_local) <> 5 or extract(hour from v_local) <> 16 then continue; end if;
    v_week := date_trunc('week', v_local)::date;

    -- The log row IS the claim: whoever inserts it sends; a parallel run
    -- finds the conflict and skips.
    insert into private.weekend_push_log (user_id, week_start) values (r.id, v_week)
    on conflict (user_id, week_start) do nothing;
    if not found then continue; end if;

    case extract(week from v_local)::int % 3
      when 0 then v_title := 'Weekend, then.';
                  v_body  := 'If you''re heading out, keep track of the night in one place. Drinks, stops, who''s live. And a way home.';
      when 1 then v_title := 'Friday''s here';
                  v_body  := 'Whatever tonight looks like, Sejdel keeps the tab so you don''t have to. Water between rounds, taxi after.';
      else        v_title := 'The weekend''s on';
                  v_body  := 'See who''s out, keep count, get home safe. That''s the whole point of it.';
    end case;

    perform private.notify_push(r.id, v_title, v_body, jsonb_build_object('type', 'weekend'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

------------------------------------------------------------------------
-- 9. Smaller windows: an RSVP that could trip the primary key when the
--    member was added by the event job at the same moment; barcode
--    consensus and terrace-facing agreement recomputed from a count that
--    another submitter was changing.
------------------------------------------------------------------------

create or replace function public.respond_to_event(p_event uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session uuid;
begin
  if p_status not in ('going', 'declined') then
    raise exception 'invalid status';
  end if;

  update event_members
     set status = p_status, responded_at = now()
   where event_id = p_event and profile_id = auth.uid();

  if p_status = 'going' then
    select e.live_session_id into v_session
      from events e
     where e.id = p_event
       and e.live_session_id is not null
       and e.live_ended_at is null;

    if v_session is not null
       and exists (select 1 from sessions s where s.id = v_session and s.active_live) then
      insert into session_members (session_id, profile_id, in_plan, in_live)
      values (v_session, auth.uid(), false, true)
      on conflict (session_id, profile_id) do update set in_live = true;
    end if;
  end if;
end $$;

create or replace function public.submit_beverage_barcode(p_barcode text, p_name text, p_category text, p_volume_ml double precision, p_abv double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sig        text;
  v_count      int;
  v_threshold  constant int := 5;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  perform pg_advisory_xact_lock(hashtext('barcode:' || p_barcode));

  -- Admin / owner bypass: trusted contributor, no vote needed.
  if exists (select 1 from app_admins where user_id = auth.uid()) then
    insert into beverage_barcodes (barcode, name, category, volume_ml, abv, created_by, updated_at)
    values (p_barcode, p_name, p_category, p_volume_ml, p_abv, auth.uid(), now())
    on conflict (barcode) do update
      set name       = excluded.name,
          category   = excluded.category,
          volume_ml  = excluded.volume_ml,
          abv        = excluded.abv,
          updated_at = now();
    return jsonb_build_object('verified', true, 'count', v_threshold, 'threshold', v_threshold, 'admin', true);
  end if;

  v_sig := lower(trim(p_name)) || '|'
        || lower(trim(p_category)) || '|'
        || round(p_volume_ml)::text || '|'
        || round(p_abv::numeric, 3)::text;

  insert into beverage_barcode_submissions
        (barcode, submitted_by, name, category, volume_ml, abv, content_sig, updated_at)
  values (p_barcode, auth.uid(), p_name, p_category, p_volume_ml, p_abv, v_sig, now())
  on conflict (barcode, submitted_by) do update
    set name        = excluded.name,
        category    = excluded.category,
        volume_ml   = excluded.volume_ml,
        abv         = excluded.abv,
        content_sig = excluded.content_sig,
        updated_at  = now();

  select count(distinct submitted_by) into v_count
  from beverage_barcode_submissions
  where barcode = p_barcode and content_sig = v_sig;

  if v_count >= v_threshold then
    insert into beverage_barcodes (barcode, name, category, volume_ml, abv, created_by, updated_at)
    values (p_barcode, p_name, p_category, p_volume_ml, p_abv, auth.uid(), now())
    on conflict (barcode) do update
      set name       = excluded.name,
          category   = excluded.category,
          volume_ml  = excluded.volume_ml,
          abv        = excluded.abv,
          updated_at = now();
    return jsonb_build_object('verified', true, 'count', v_count, 'threshold', v_threshold, 'admin', false);
  end if;

  return jsonb_build_object('verified', false, 'count', v_count, 'threshold', v_threshold, 'admin', false);
end $$;

create or replace function public.report_sun_facade(p_venue uuid, p_bearing smallint)
returns smallint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_agreed smallint; v_n smallint;
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_bearing is null or p_bearing < 0 or p_bearing >= 360 then
    raise exception 'bad_bearing';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;
  perform pg_advisory_xact_lock(hashtext('facade:' || p_venue::text));

  insert into venue_sun_facade_reports (venue_id, profile_id, bearing)
  values (p_venue, v_uid, p_bearing)
  on conflict (venue_id, profile_id)
    do update set bearing = excluded.bearing, created_at = now();

  select public.agreed_facade_bearing(p_venue) into v_agreed;
  select count(*) into v_n from venue_sun_facade_reports where venue_id = p_venue;

  -- venue_sun may not have a row yet for a brand-new venue.
  insert into venue_sun (venue_id, horizon, confidence, source, computed_at,
                         facade_bearing, facade_reports)
  values (p_venue, array_fill(0::smallint, array[72]), 0, 'pending', now(),
          v_agreed, v_n)
  on conflict (venue_id) do update
    set facade_bearing = v_agreed, facade_reports = v_n;

  return v_agreed;
end $$;
