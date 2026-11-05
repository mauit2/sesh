


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."appstore_check"("p_transaction_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private', 'extensions'
    AS $$
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


ALTER FUNCTION "private"."appstore_check"("p_transaction_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."biz_limit"("p_key" "text") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select value from business_limits where key = p_key
$$;


ALTER FUNCTION "private"."biz_limit"("p_key" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."business_products" (
    "product_id" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "quantity" integer NOT NULL,
    "amount_sek" integer NOT NULL,
    "label" "text" NOT NULL,
    "sort" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "business_products_kind_check" CHECK (("kind" = ANY (ARRAY['subscription'::"text", 'boost'::"text", 'card'::"text", 'push'::"text"])))
);


ALTER TABLE "public"."business_products" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."biz_product"("p_kind" "text", "p_quantity" integer) RETURNS "public"."business_products"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from business_products where kind = p_kind and quantity = p_quantity limit 1
$$;


ALTER FUNCTION "private"."biz_product"("p_kind" "text", "p_quantity" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."biz_tier"("p_business" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce((
    select case when b.status = 'approved' and b.tier <> 'none'
                     and (b.tier_expires_at is null or b.tier_expires_at > now())
                then b.tier else 'none' end
    from businesses b where b.id = p_business), 'none')
$$;


ALTER FUNCTION "private"."biz_tier"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."biz_username"("p_name" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare base text; cand text; n integer := 0;
begin
  base := regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '', 'g');
  if length(base) < 3 then base := base || 'bar'; end if;
  base := left(base, 16);
  loop
    cand := case when n = 0 then base else base || n::text end;
    exit when not exists (select 1 from profiles where lower(username) = cand)
         and not exists (select 1 from businesses where username = cand and status <> 'ended');
    n := n + 1;
  end loop;
  return cand;
end $$;


ALTER FUNCTION "private"."biz_username"("p_name" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."businesses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "org_number" "text",
    "contact_email" "text" NOT NULL,
    "contact_phone" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "admin_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "tier" "text" DEFAULT 'none'::"text" NOT NULL,
    "tier_product_id" "text",
    "tier_expires_at" timestamp with time zone,
    "apple_original_transaction_id" "text",
    "tier_synced_at" timestamp with time zone,
    "logo_url" "text",
    "poster_url" "text",
    "tagline" "text",
    "username" "text",
    "prior_name" "text",
    "prior_username" "text",
    "prior_avatar_url" "text",
    "ended_at" timestamp with time zone,
    "list_days" smallint[] DEFAULT '{1,2,3,4,5,6,7}'::smallint[] NOT NULL,
    CONSTRAINT "businesses_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'suspended'::"text", 'ended'::"text"]))),
    CONSTRAINT "businesses_tier_check" CHECK (("tier" = ANY (ARRAY['none'::"text", 'business'::"text", 'plus'::"text"])))
);


ALTER TABLE "public"."businesses" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_for_owner"("p_business" "uuid", "p_require_approved" boolean) RETURNS "public"."businesses"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare b public.businesses;
begin
  select * into b from businesses where id = p_business and owner_id = auth.uid();
  if b.id is null then raise exception 'not_owner'; end if;
  if p_require_approved and b.status <> 'approved' then raise exception 'not_approved'; end if;
  return b;
end $$;


ALTER FUNCTION "private"."business_for_owner"("p_business" "uuid", "p_require_approved" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_order_sync"("p_order" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "private"."business_order_sync"("p_order" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_post_counts"("p_post" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'like_count', (select count(*) from business_post_likes l where l.post_id = p_post),
    'liked_by_me', exists (select 1 from business_post_likes l where l.post_id = p_post and l.user_id = auth.uid()),
    'comment_count', (select count(*) from business_post_comments c where c.post_id = p_post and c.deleted_at is null),
    'views', coalesce((select sum(s.impressions) from campaign_stats s where s.campaign_id = p_post), 0))
$$;


ALTER FUNCTION "private"."business_post_counts"("p_post" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_post_visible"("p_post" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select exists (select 1 from business_posts p join businesses b on b.id = p.business_id
                 where p.id = p_post and p.deleted_at is null and b.status = 'approved' and private.biz_tier(b.id) <> 'none')
$$;


ALTER FUNCTION "private"."business_post_visible"("p_post" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_revert"("p_business" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v_user text;
begin
  select * into b from businesses where id = p_business;
  if b.id is null then return; end if;
  v_user := b.prior_username;
  if v_user is not null and exists (select 1 from profiles where lower(username) = lower(v_user) and id <> b.owner_id) then
    v_user := null;   -- someone took it meanwhile; they pick a new one
  end if;
  update profiles
     set name = coalesce(b.prior_name, name), username = v_user, avatar_url = b.prior_avatar_url, business_id = null
   where id = b.owner_id and business_id = b.id;
  update business_posts set deleted_at = now() where business_id = b.id and deleted_at is null;
  update business_boosts set status = 'cancelled' where business_id = b.id and status in ('pending','live');
  update business_cards set status = 'cancelled' where business_id = b.id and status in ('pending','live');
  update business_pushes set status = 'cancelled' where business_id = b.id and status in ('pending','approved');
  update business_orders set status = 'cancelled' where business_id = b.id and status in ('pending','approved') and not paid;
  update business_events set cancelled_at = now() where business_id = b.id and cancelled_at is null;
  update venue_offers set is_active = false where business_id = b.id;
  update businesses set status = 'ended', tier = 'none', tier_product_id = null, tier_expires_at = null, ended_at = now()
   where id = b.id;
  perform private.business_sync_presence(b.id);
end $$;


ALTER FUNCTION "private"."business_revert"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_sync_presence"("p_business" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v_tier text;
begin
  select * into b from businesses where id = p_business;
  if b.id is null then return; end if;
  v_tier := private.biz_tier(b.id);
  update venues
     set tier = case v_tier when 'plus' then 'poster' when 'business' then 'pin' else 'none' end
   where id = b.venue_id and tier <> 'billboard';
  update venue_offers
     set approved  = (v_tier <> 'none'),
         placement = case when v_tier = 'plus' and image_url is not null then 'poster' else 'pin' end
   where business_id = b.id and is_active and placement <> 'billboard';
  if v_tier <> 'plus' then
    update business_boosts set status = 'cancelled' where business_id = b.id and status = 'pending';
  end if;
end $$;


ALTER FUNCTION "private"."business_sync_presence"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."business_takeover"("p_business" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v public.venues; pr public.profiles; u text;
begin
  select * into b from businesses where id = p_business;
  if b.id is null then return; end if;
  select * into v from venues where id = b.venue_id;
  select * into pr from profiles where id = b.owner_id;
  if pr.id is null then return; end if;
  if b.prior_name is null then
    update businesses set prior_name = pr.name, prior_username = pr.username, prior_avatar_url = pr.avatar_url
     where id = b.id;
  end if;
  u := coalesce(b.username, private.biz_username(v.name));
  update businesses set username = u where id = b.id;
  update profiles set name = v.name, username = u, business_id = b.id,
         avatar_url = coalesce(b.logo_url, avatar_url)
   where id = b.owner_id;
end $$;


ALTER FUNCTION "private"."business_takeover"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."can_edit_event"("p_event" "uuid", "p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from events e
    where e.id = p_event
      and (
        e.host_id = p_user
        or (
          e.edit_mode = 'everyone'
          and exists (
            select 1 from event_members m
            where m.event_id = p_event
              and m.profile_id = p_user
              and m.status = 'going'
          )
        )
      )
  );
$$;


ALTER FUNCTION "private"."can_edit_event"("p_event" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."cleanup_snaps_http"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare cfg private.push_config;
begin
  select * into cfg from private.push_config where id = 1;
  if cfg.function_url is null then return; end if;
  perform net.http_post(
    url     := replace(cfg.function_url, '/send-push', '/cleanup-snaps'),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || cfg.secret),
    body    := '{}'::jsonb
  );
exception when others then
  return;
end $$;


ALTER FUNCTION "private"."cleanup_snaps_http"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."friends_live_pulse_for"("p_me" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_agg(e.entry order by e.name), '[]'::jsonb)
  from (
    select f.name,
      jsonb_build_object('id', f.id, 'name', f.name, 'username', f.username,
                         'avatar_url', f.avatar_url, 'live', false)
      || case when pres.user_id is null then '{}'::jsonb else jsonb_build_object(
           'live', true,
           'bac', round(widmark_bac(ev.events, f.weight_kg, f.sex, now())::numeric, 3),
           'drinks', ev.cnt,
           'venue', coalesce(sess.live_venue->>'name', pres.venue_name),
           'venue_lat', coalesce((sess.live_venue->>'lat')::float8, pres.venue_lat),
           'venue_lon', coalesce((sess.live_venue->>'lon')::float8, pres.venue_lon),
           'started_epoch', extract(epoch from pres.started_at),
           'members', coalesce(mems.arr, '[]'::jsonb)) end as entry
    from friendships fr
    join profiles f
      on f.id = case when fr.requester_id = p_me then fr.addressee_id else fr.requester_id end
    -- A friend's presence row, if it is a live night (started, seen in 16 h).
    left join live_presence pres
      on pres.user_id = f.id
     and pres.started_at is not null
     and pres.updated_at > now() - interval '16 hours'
    -- Their live group, if the presence points at one that is still running.
    left join sessions sess
      on sess.id = pres.session_id and sess.active_live
    -- Headcount a shared round divides by: live members + guests. Mirrors
    -- the client's sharedHeadCount exactly.
    left join lateral (
      select greatest(count(*) + coalesce(jsonb_array_length(sess.ghosts), 0), 1) as n
        from session_members sm
       where sm.session_id = sess.id and sm.in_live
    ) h on sess.id is not null
    -- The friend's own ledger: in a group, personal drinks at full grams and
    -- shared rounds at their per-head share; solo, the presence row's drinks.
    left join lateral (
      select x.events, (select count(*) from jsonb_array_elements(x.events)) as cnt
        from (select case when sess.id is null then coalesce(pres.drinks, '[]'::jsonb)
                     else coalesce((
                       select jsonb_agg(jsonb_build_object('t', d.created_at,
                                'g', (d.volume_ml * d.abv * 0.789) / case when d.shared then h.n else 1 end)
                              order by d.created_at)
                         from session_drinks d
                        where d.session_id = sess.id and d.live
                          and (d.profile_id = f.id or d.shared)), '[]'::jsonb)
                     end as events) x
    ) ev on pres.user_id is not null
    -- Everyone else in the group, same per-head math.
    left join lateral (
      select jsonb_agg(jsonb_build_object(
               'id', mp.id, 'name', mp.name, 'avatar_url', mp.avatar_url,
               'drinks', (select count(*) from session_drinks d2
                           where d2.session_id = sess.id and d2.live
                             and (d2.profile_id = mp.id or d2.shared)),
               'bac', round(widmark_bac(
                        (select coalesce(jsonb_agg(jsonb_build_object('t', d3.created_at,
                                  'g', (d3.volume_ml * d3.abv * 0.789) / case when d3.shared then h.n else 1 end)
                                order by d3.created_at), '[]'::jsonb)
                           from session_drinks d3
                          where d3.session_id = sess.id and d3.live
                            and (d3.profile_id = mp.id or d3.shared)),
                        mp.weight_kg, mp.sex, now())::numeric, 3))) as arr
        from session_members sm
        join profiles mp on mp.id = sm.profile_id
       where sm.session_id = sess.id and sm.in_live and sm.profile_id <> f.id
    ) mems on sess.id is not null
    where fr.status = 'accepted'
      and (fr.requester_id = p_me or fr.addressee_id = p_me)
  ) e;
$$;


ALTER FUNCTION "private"."friends_live_pulse_for"("p_me" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_app_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from app_admins where user_id = auth.uid())
$$;


ALTER FUNCTION "private"."is_app_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."list_request_reply"("p_request" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare r list_requests; v_account uuid;
begin
  select * into r from list_requests where id = p_request;
  if r.id is null or r.status = 'pending' then return; end if;
  select id into v_account from profiles where business_id = r.business_id limit 1;
  if v_account is null then return; end if;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_account, r.user_id, 'text',
    case when r.status = 'approved'
      then format('You''re on the list for %s — %s +%s. See you at the door 🎉', to_char(r.night, 'Dy FMDD Mon'), r.full_name, r.plus_count)
      else format('Sorry — the list for %s is full.', to_char(r.night, 'Dy FMDD Mon')) end,
    r.id);
end $$;


ALTER FUNCTION "private"."list_request_reply"("p_request" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."notify_business_followers"("p_business" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_owner uuid; v_ids uuid[];
begin
  select owner_id into v_owner from businesses where id = p_business;
  select coalesce(array_agg(user_id), '{}'::uuid[]) into v_ids
    from business_follows
   where business_id = p_business and notify
     and user_id is distinct from v_owner
     and (last_notified_at is null or last_notified_at < now() - interval '2 hours');
  perform private.notify_push(u, p_title, p_body, p_data) from unnest(v_ids) as u;
  -- One UPDATE for the whole batch instead of one per follower.
  update business_follows set last_notified_at = now()
   where business_id = p_business and user_id = any(v_ids);
  return coalesce(array_length(v_ids, 1), 0);
end $$;


ALTER FUNCTION "private"."notify_business_followers"("p_business" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."notify_push"("p_user" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if p_user is null then return; end if;
  insert into private.push_outbox (user_id, title, body, data)
  values (p_user, coalesce(p_title, ''), coalesce(p_body, ''), coalesce(p_data, '{}'::jsonb));
exception when others then
  return;
end $$;


ALTER FUNCTION "private"."notify_push"("p_user" "uuid", "p_title" "text", "p_body" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."on_session_live_ended"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  m record;
  ender uuid := auth.uid();   -- null when the cron ends it
begin
  if old.active_live and not new.active_live then
    for m in
      select profile_id from session_members
       where session_id = new.id and in_live
         and (ender is null or profile_id <> ender)
    loop
      perform private.notify_push(
        m.profile_id,
        '🍻 The night is over',
        'Your recap is ready — open Sejdel to see it.',
        jsonb_build_object('type', 'session_ended', 'session_id', new.id)
      );
    end loop;
  end if;
  return new;
exception when others then
  return new;
end $$;


ALTER FUNCTION "private"."on_session_live_ended"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_business_presence"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare r record; n integer := 0;
begin
  for r in select id from businesses where status <> 'ended' and tier <> 'none' and tier_expires_at is not null
              and tier_expires_at <= now() - interval '1 day'   -- a day of grace for a late renewal
  loop
    perform private.business_revert(r.id); n := n + 1;
  end loop;
  return n;
end $$;


ALTER FUNCTION "private"."run_business_presence"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_business_pushes"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  p record; v public.venues; v_tz text; v_hour integer; v_count integer; v_total integer := 0;
  c_radius integer := private.biz_limit('radius_m');
  c_weekly integer := private.biz_limit('user_push_weekly_max');
  c_qs integer := private.biz_limit('quiet_start_hour');
  c_qe integer := private.biz_limit('quiet_end_hour');
begin
  for p in
    select bp.* from business_pushes bp
    join business_orders o on o.push_id = bp.id
    where bp.status = 'approved' and o.status = 'approved' and o.paid and bp.send_at <= now()
    order by bp.send_at
    for update of bp skip locked
  loop
    select vv.* into v from venues vv join businesses b on b.venue_id = vv.id
     where b.id = p.business_id and b.status = 'approved';
    if v.id is null then update business_pushes set status = 'failed' where id = p.id; continue; end if;
    v_tz := coalesce(v.time_zone, 'Europe/Stockholm');
    v_hour := extract(hour from (now() at time zone v_tz))::int;
    if v_hour >= c_qs and v_hour < c_qe then continue; end if;
    if p.offer_id is not null and not exists (
         select 1 from venue_offers o where o.id = p.offer_id and o.is_active and o.approved
            and (o.ends_at is null or o.ends_at > now())) then
      update business_pushes set status = 'failed' where id = p.id; continue;
    end if;

    with aud as (
      select pr.id
        from profiles pr
       where pr.deals_push_opt_in
         and pr.deals_lat is not null and pr.deals_lon is not null
         and pr.deals_loc_at > now() - interval '30 days'
         and public.haversine_m(pr.deals_lat, pr.deals_lon, v.lat, v.lon) <= c_radius
         and (select count(*) from business_push_receipts r
               where r.user_id = pr.id and r.sent_at > now() - interval '7 days') < c_weekly
       order by (select max(r.sent_at) from business_push_receipts r where r.user_id = pr.id) nulls first, random()
       limit p.audience_cap
    ), ins as (
      insert into business_push_receipts (push_id, user_id) select p.id, aud.id from aud returning user_id
    )
    select count(*) into v_count from ins;

    perform private.notify_push(r.user_id, p.title, p.body,
              jsonb_build_object('type','deal','venue_id', v.id, 'offer_id', p.offer_id, 'business_push_id', p.id))
       from business_push_receipts r where r.push_id = p.id;

    update business_pushes set status = 'sent', sent_at = now(), recipient_count = v_count where id = p.id;
    update business_orders set detail = coalesce(detail, '') || format(' · reached %s', v_count) where push_id = p.id;
    insert into venue_push_log (venue_id, offer_id, sent_by, title, body, recipient_count)
    select v.id, p.offer_id, b.owner_id, p.title, p.body, v_count from businesses b where b.id = p.business_id;
    v_total := v_total + 1;
  end loop;
  return v_total;
end $$;


ALTER FUNCTION "private"."run_business_pushes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_group_autoend"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  update sessions s
     set active_live = false
   where s.active_live
     and not exists (select 1 from events e
                      where e.live_session_id = s.id and e.live_ended_at is null)
     and greatest(
           s.created_at,
           coalesce((select max(d.created_at)  from session_drinks d  where d.session_id  = s.id), s.created_at),
           coalesce((select max(st.arrived_at) from session_stops st  where st.session_id = s.id), s.created_at),
           coalesce((select max(sn.created_at) from session_snaps sn  where sn.session_id = s.id), s.created_at)
         ) < now() - interval '8 hours';
exception when others then
  return;
end $$;


ALTER FUNCTION "private"."run_group_autoend"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_push_outbox"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare cfg private.push_config; r record; n integer := 0;
begin
  select * into cfg from private.push_config where id = 1;
  if cfg.function_url is null then return 0; end if;
  for r in
    select * from private.push_outbox
     where sent_at is null
     order by id
     limit 500
     for update skip locked
  loop
    begin
      perform net.http_post(
        url     := cfg.function_url,
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'Authorization', 'Bearer ' || cfg.secret),
        body    := jsonb_build_object(
                     'user_id', r.user_id, 'title', r.title, 'body', r.body, 'data', r.data,
                     'badge', private.unseen_count(r.user_id))
      );
      update private.push_outbox set sent_at = now() where id = r.id;
      n := n + 1;
    exception when others then
      -- Leave the row pending; the next run retries it.
      null;
    end;
  end loop;
  -- Sent rows are only an audit trail; a week is plenty.
  delete from private.push_outbox where sent_at < now() - interval '7 days';
  -- pg_cron logs every run; at four runs a minute that is 5,760 rows a day
  -- (the minute-cadence jobs already add 2,880). Keep two days.
  delete from cron.job_run_details where end_time < now() - interval '2 days';
  return n;
end $$;


ALTER FUNCTION "private"."run_push_outbox"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_weekend_push"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "private"."run_weekend_push"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."speakeasy_matches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "host_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "n" integer NOT NULL,
    "phase" "text" NOT NULL,
    "players" "jsonb" NOT NULL,
    "deck" "text"[] NOT NULL,
    "discard" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "enacted_h" integer DEFAULT 0 NOT NULL,
    "enacted_r" integer DEFAULT 0 NOT NULL,
    "tracker" integer DEFAULT 0 NOT NULL,
    "president" integer NOT NULL,
    "chancellor" integer,
    "last_president" integer,
    "last_chancellor" integer,
    "votes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "hand" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "c_hand" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "special_origin" integer,
    "veto_unlocked" boolean DEFAULT false NOT NULL,
    "veto_denied" boolean DEFAULT false NOT NULL,
    "investigated" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "investigation" "jsonb",
    "peek" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "last_vote" "jsonb",
    "log" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "winner" "text",
    "win_reason" "text"
);


ALTER TABLE "public"."speakeasy_matches" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_advance"("m" "public"."speakeasy_matches") RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
  m.chancellor := null; m.votes := '{}'::jsonb; m.hand := '{}'; m.c_hand := '{}';
  m.peek := '{}'; m.investigation := null; m.veto_denied := false;
  if m.special_origin is not null then
    m.president := private.se_next_alive(m.players, m.special_origin);
    m.special_origin := null;
  else
    m.president := private.se_next_alive(m.players, m.president);
  end if;
  m.phase := 'nominate';
  return m;
end $$;


ALTER FUNCTION "private"."se_advance"("m" "public"."speakeasy_matches") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_alive_count"("players" "jsonb") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select count(*)::int from jsonb_array_elements(players) p where (p->>'alive')::boolean;
$$;


ALTER FUNCTION "private"."se_alive_count"("players" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_enact"("m" "public"."speakeasy_matches", "card" "text", "with_power" boolean) RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql"
    AS $$
declare power text;
begin
  m.veto_denied := false;
  if card = 'H' then
    m.enacted_h := m.enacted_h + 1;
    m := private.se_log(m, 'HAPPY HOUR enacted (' || m.enacted_h || '/5)');
    m := private.se_reshuffle(m);
    if m.enacted_h >= 5 then return private.se_win(m, 'patrons', 'five Happy Hours'); end if;
    return private.se_advance(m);
  end if;
  m.enacted_r := m.enacted_r + 1;
  m := private.se_log(m, 'RACKET enacted (' || m.enacted_r || '/6)');
  if m.enacted_r >= 5 then m.veto_unlocked := true; end if;
  m := private.se_reshuffle(m);
  if m.enacted_r >= 6 then return private.se_win(m, 'bootleggers', 'six Rackets'); end if;
  if with_power then
    power := (private.se_powers(m.n))[m.enacted_r];
    if power <> '' and power <> 'win' then
      m.phase := power;
      if power = 'peek' then m.peek := m.deck[1:3]; end if;
      m := private.se_log(m, private.se_name(m.players, m.president) || ' gets ' ||
             case power when 'peek' then 'PEEK THE TAB' when 'investigate' then 'ID CHECK'
                        when 'special' then 'SKIP THE LINE' else 'CUT OFF' end);
      return m;
    end if;
  end if;
  return private.se_advance(m);
end $$;


ALTER FUNCTION "private"."se_enact"("m" "public"."speakeasy_matches", "card" "text", "with_power" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_log"("m" "public"."speakeasy_matches", "msg" "text") RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare len int;
begin
  m.log := m.log || to_jsonb(coalesce(msg, ''));
  len := jsonb_array_length(m.log);
  if len > 40 then
    m.log := (select coalesce(jsonb_agg(x order by o), '[]'::jsonb)
              from jsonb_array_elements(m.log) with ordinality as t(x, o)
              where o > len - 40);
  end if;
  return m;
end $$;


ALTER FUNCTION "private"."se_log"("m" "public"."speakeasy_matches", "msg" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_name"("players" "jsonb", "idx" integer) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select players->idx->>'name' $$;


ALTER FUNCTION "private"."se_name"("players" "jsonb", "idx" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_next_alive"("players" "jsonb", "from_idx" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare n int := jsonb_array_length(players); i int; k int;
begin
  for k in 1..n loop
    i := (from_idx + k) % n;
    if (players->i->>'alive')::boolean then return i; end if;
  end loop;
  return from_idx;
end $$;


ALTER FUNCTION "private"."se_next_alive"("players" "jsonb", "from_idx" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_powers"("n" integer) RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case when n <= 6 then array['', '', 'peek', 'execute', 'execute', 'win']
              when n <= 8 then array['', 'investigate', 'special', 'execute', 'execute', 'win']
              else array['investigate', 'investigate', 'special', 'execute', 'execute', 'win'] end;
$$;


ALTER FUNCTION "private"."se_powers"("n" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_reshuffle"("m" "public"."speakeasy_matches") RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql"
    AS $$
begin
  if coalesce(array_length(m.deck, 1), 0) < 3 then
    m.deck := private.se_shuffle(m.deck || m.discard);
    m.discard := '{}';
    m := private.se_log(m, 'Deck reshuffled');
  end if;
  return m;
end $$;


ALTER FUNCTION "private"."se_reshuffle"("m" "public"."speakeasy_matches") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_resolve_vote"("m" "public"."speakeasy_matches") RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql"
    AS $$
declare ja int; nein int; card text;
begin
  select count(*) filter (where v::boolean), count(*) filter (where not v::boolean)
    into ja, nein from jsonb_each_text(m.votes) as t(k, v);
  m.last_vote := jsonb_build_object('ja', ja, 'nein', nein, 'passed', ja > nein, 'by', m.votes,
                                    'president', m.president, 'chancellor', m.chancellor);
  if ja > nein then
    m := private.se_log(m, 'Vote passed ' || ja || '–' || nein || ': ' ||
           private.se_name(m.players, m.president) || ' & ' || private.se_name(m.players, m.chancellor));
    m.tracker := 0;
    m.last_president := m.president; m.last_chancellor := m.chancellor;
    if m.enacted_r >= 3 and m.players->m.chancellor->>'role' = 'boss' then
      return private.se_win(m, 'bootleggers', 'The Boss was made Barkeep');
    end if;
    m := private.se_reshuffle(m);
    m.hand := m.deck[1:3];
    m.deck := m.deck[4:array_length(m.deck, 1)];
    m.phase := 'president';
    return m;
  end if;
  m.tracker := m.tracker + 1;
  m := private.se_log(m, 'Vote failed ' || ja || '–' || nein || ' (' || m.tracker || '/3)');
  if m.tracker >= 3 then
    m := private.se_log(m, 'Chaos — top card enacted blind');
    m.tracker := 0; m.last_president := null; m.last_chancellor := null;
    card := m.deck[1];
    m.deck := m.deck[2:array_length(m.deck, 1)];
    return private.se_enact(m, card, false);
  end if;
  return private.se_advance(m);
end $$;


ALTER FUNCTION "private"."se_resolve_vote"("m" "public"."speakeasy_matches") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_seat"("players" "jsonb", "uid" "uuid") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select (o - 1)::int from jsonb_array_elements(players) with ordinality as t(p, o)
  where (p->>'id')::uuid = uid limit 1;
$$;


ALTER FUNCTION "private"."se_seat"("players" "jsonb", "uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_shuffle"("arr" "text"[]) RETURNS "text"[]
    LANGUAGE "sql"
    AS $$
  select coalesce(array_agg(x order by random()), '{}'::text[]) from unnest(arr) x;
$$;


ALTER FUNCTION "private"."se_shuffle"("arr" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."se_win"("m" "public"."speakeasy_matches", "who" "text", "why" "text") RETURNS "public"."speakeasy_matches"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
  m.winner := who; m.win_reason := why; m.phase := 'over';
  m := private.se_log(m, case when who = 'patrons' then 'PATRONS WIN — ' else 'BOOTLEGGERS WIN — ' end || why);
  return m;
end $$;


ALTER FUNCTION "private"."se_win"("m" "public"."speakeasy_matches", "who" "text", "why" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."speakeasy_apply"("p_match" "uuid", "p_actor" "uuid", "p_action" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  m public.speakeasy_matches%rowtype;
  me int; kind text; target uuid; tseat int; idx int; card text; other text; alive int;
begin
  select * into m from public.speakeasy_matches where id = p_match for update;
  if not found then raise exception 'no such match'; end if;
  if m.phase = 'over' then raise exception 'the game is over'; end if;
  me := private.se_seat(m.players, p_actor);
  if me is null then raise exception 'you are not in this game'; end if;
  if not (m.players->me->>'alive')::boolean then raise exception 'you were cut off'; end if;
  kind := p_action->>'type';
  alive := private.se_alive_count(m.players);

  if kind = 'nominate' then
    if m.phase <> 'nominate' or me <> m.president then raise exception 'not your call'; end if;
    target := (p_action->>'target')::uuid; tseat := private.se_seat(m.players, target);
    if tseat is null or not (m.players->tseat->>'alive')::boolean or tseat = me then raise exception 'invalid nominee'; end if;
    if tseat = m.last_chancellor then raise exception 'term-limited'; end if;
    if tseat = m.last_president and alive > 5 then raise exception 'term-limited'; end if;
    m.chancellor := tseat; m.votes := '{}'::jsonb; m.phase := 'vote';
    m := private.se_log(m, private.se_name(m.players, me) || ' nominates ' || private.se_name(m.players, tseat));

  elsif kind = 'vote' then
    if m.phase <> 'vote' then raise exception 'no vote running'; end if;
    m.votes := m.votes || jsonb_build_object(p_actor::text, (p_action->>'ja')::boolean);
    if (select count(*) from jsonb_object_keys(m.votes)) >= alive then
      m := private.se_resolve_vote(m);
    end if;

  elsif kind = 'discard' then
    if m.phase <> 'president' or me <> m.president then raise exception 'not your call'; end if;
    idx := (p_action->>'index')::int + 1;
    if idx < 1 or idx > 3 then raise exception 'bad card'; end if;
    m.discard := m.discard || m.hand[idx];
    m.c_hand := array_remove(m.hand, null);
    m.c_hand := m.hand[1:idx-1] || m.hand[idx+1:3];
    m.hand := '{}'; m.phase := 'chancellor';
    m := private.se_log(m, private.se_name(m.players, me) || ' passes two cards to ' || private.se_name(m.players, m.chancellor));

  elsif kind = 'enact' then
    if m.phase <> 'chancellor' or me <> m.chancellor then raise exception 'not your call'; end if;
    idx := (p_action->>'index')::int + 1;
    if idx < 1 or idx > 2 then raise exception 'bad card'; end if;
    card := m.c_hand[idx]; other := m.c_hand[3 - idx];
    m.discard := m.discard || other; m.c_hand := '{}';
    m := private.se_enact(m, card, true);

  elsif kind = 'veto' then
    if m.phase <> 'chancellor' or me <> m.chancellor then raise exception 'not your call'; end if;
    if not m.veto_unlocked or m.veto_denied then raise exception 'veto not available'; end if;
    m.phase := 'veto';
    m := private.se_log(m, private.se_name(m.players, me) || ' wants to call it off');

  elsif kind = 'veto_reply' then
    if m.phase <> 'veto' or me <> m.president then raise exception 'not your call'; end if;
    if (p_action->>'agree')::boolean then
      m.discard := m.discard || m.c_hand; m.c_hand := '{}';
      m.tracker := m.tracker + 1;
      m := private.se_log(m, 'Round called off (' || m.tracker || '/3)');
      m := private.se_reshuffle(m);
      if m.tracker >= 3 then
        m := private.se_log(m, 'Chaos — top card enacted blind');
        m.tracker := 0; m.last_president := null; m.last_chancellor := null;
        card := m.deck[1]; m.deck := m.deck[2:array_length(m.deck, 1)];
        m := private.se_enact(m, card, false);
      else
        m := private.se_advance(m);
      end if;
    else
      m.veto_denied := true; m.phase := 'chancellor';
      m := private.se_log(m, private.se_name(m.players, me) || ' refuses — a card must be played');
    end if;

  elsif kind = 'investigate' then
    if m.phase <> 'investigate' or me <> m.president then raise exception 'not your call'; end if;
    target := (p_action->>'target')::uuid; tseat := private.se_seat(m.players, target);
    if tseat is null or tseat = me or not (m.players->tseat->>'alive')::boolean or target = any(m.investigated) then
      raise exception 'invalid target';
    end if;
    m.investigated := m.investigated || target;
    m.investigation := jsonb_build_object('target', target, 'name', private.se_name(m.players, tseat),
      'party', case when m.players->tseat->>'role' = 'patron' then 'patron' else 'bootlegger' end);
    m.phase := 'investigate_result';
    m := private.se_log(m, private.se_name(m.players, me) || ' checks ' || private.se_name(m.players, tseat) || '''s ID');

  elsif kind = 'continue' then
    if m.phase not in ('investigate_result', 'peek') or me <> m.president then raise exception 'not your call'; end if;
    m := private.se_advance(m);

  elsif kind = 'special' then
    if m.phase <> 'special' or me <> m.president then raise exception 'not your call'; end if;
    target := (p_action->>'target')::uuid; tseat := private.se_seat(m.players, target);
    if tseat is null or tseat = me or not (m.players->tseat->>'alive')::boolean then raise exception 'invalid target'; end if;
    m.special_origin := m.president; m.president := tseat;
    m.chancellor := null; m.votes := '{}'::jsonb; m.peek := '{}'; m.investigation := null;
    m.phase := 'nominate';
    m := private.se_log(m, private.se_name(m.players, tseat) || ' skips the line as Host');

  elsif kind = 'execute' then
    if m.phase <> 'execute' or me <> m.president then raise exception 'not your call'; end if;
    target := (p_action->>'target')::uuid; tseat := private.se_seat(m.players, target);
    if tseat is null or tseat = me or not (m.players->tseat->>'alive')::boolean then raise exception 'invalid target'; end if;
    m.players := jsonb_set(m.players, array[tseat::text, 'alive'], 'false'::jsonb);
    m := private.se_log(m, private.se_name(m.players, tseat) || ' is cut off');
    if m.players->tseat->>'role' = 'boss' then
      m := private.se_win(m, 'patrons', 'The Boss was cut off');
    else
      m := private.se_advance(m);
    end if;

  else
    raise exception 'unknown action %', kind;
  end if;

  m.updated_at := now();
  update public.speakeasy_matches set
    phase = m.phase, players = m.players, deck = m.deck, discard = m.discard,
    enacted_h = m.enacted_h, enacted_r = m.enacted_r, tracker = m.tracker,
    president = m.president, chancellor = m.chancellor,
    last_president = m.last_president, last_chancellor = m.last_chancellor,
    votes = m.votes, hand = m.hand, c_hand = m.c_hand, special_origin = m.special_origin,
    veto_unlocked = m.veto_unlocked, veto_denied = m.veto_denied,
    investigated = m.investigated, investigation = m.investigation, peek = m.peek,
    last_vote = m.last_vote, log = m.log, winner = m.winner, win_reason = m.win_reason,
    updated_at = m.updated_at
  where id = m.id;
end $$;


ALTER FUNCTION "private"."speakeasy_apply"("p_match" "uuid", "p_actor" "uuid", "p_action" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."speakeasy_create"("p_session" "uuid", "p_host" "uuid", "p_players" "uuid"[]) RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
declare
  n int; k int; order_ids uuid[]; roles text[]; players jsonb := '[]'::jsonb; i int; nm text; new_id uuid;
begin
  select array_agg(distinct x) into order_ids from unnest(p_players) x;
  n := coalesce(array_length(order_ids, 1), 0);
  if n < 5 or n > 10 then raise exception 'Speakeasy needs 5 to 10 players'; end if;
  if not (p_host = any(order_ids)) then raise exception 'host must play'; end if;
  order_ids := (select array_agg(x order by random()) from unnest(order_ids) x);
  k := case when n <= 6 then 1 when n <= 8 then 2 else 3 end;
  roles := array['boss'] || array_fill('bootlegger'::text, array[k]) || array_fill('patron'::text, array[n - 1 - k]);
  roles := private.se_shuffle(roles);
  for i in 1..n loop
    nm := null;
    select name into nm from public.profiles where id = order_ids[i];
    players := players || jsonb_build_object('id', order_ids[i], 'name', coalesce(nullif(trim(nm), ''), 'Player ' || i),
                                             'role', roles[i], 'alive', true);
  end loop;
  insert into public.speakeasy_matches (session_id, host_id, n, phase, players, deck, president, log)
  values (p_session, p_host, n, 'nominate', players,
          private.se_shuffle(array_fill('H'::text, array[6]) || array_fill('R'::text, array[11])),
          0, jsonb_build_array('The night begins. ' || (players->0->>'name') || ' hosts first.'))
  returning id into new_id;
  return new_id;
end $$;


ALTER FUNCTION "private"."speakeasy_create"("p_session" "uuid", "p_host" "uuid", "p_players" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."speakeasy_view_for"("m" "public"."speakeasy_matches", "uid" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  me int; my_role text; alive int; eligible jsonb; allies jsonb := '[]'::jsonb; pub_players jsonb; v jsonb;
begin
  me := private.se_seat(m.players, uid);
  my_role := m.players->me->>'role';
  alive := private.se_alive_count(m.players);

  pub_players := (select coalesce(jsonb_agg(jsonb_build_object(
      'id', p->>'id', 'name', p->>'name', 'alive', (p->>'alive')::boolean, 'seat', o - 1,
      'role', case when m.phase = 'over' then p->>'role' else null end,
      'voted', case when m.phase = 'vote' then (m.votes ? (p->>'id')) else null end,
      'investigated', ((p->>'id')::uuid = any(m.investigated))
    ) order by o), '[]'::jsonb)
    from jsonb_array_elements(m.players) with ordinality as t(p, o));

  if my_role in ('bootlegger', 'boss') and (my_role = 'bootlegger' or m.n <= 6) then
    allies := (select coalesce(jsonb_agg(jsonb_build_object('id', p->>'id', 'name', p->>'name', 'role', p->>'role') order by o), '[]'::jsonb)
               from jsonb_array_elements(m.players) with ordinality as t(p, o)
               where p->>'role' in ('bootlegger', 'boss') and (p->>'id')::uuid <> uid);
  end if;

  eligible := '[]'::jsonb;
  if me = m.president and m.phase in ('nominate', 'investigate', 'special', 'execute') then
    eligible := (select coalesce(jsonb_agg(p->>'id' order by o), '[]'::jsonb)
                 from jsonb_array_elements(m.players) with ordinality as t(p, o)
                 where (p->>'alive')::boolean and (o - 1) <> me
                   and (m.phase <> 'nominate' or ((o - 1) is distinct from m.last_chancellor
                        and ((o - 1) is distinct from m.last_president or alive <= 5)))
                   and (m.phase <> 'investigate' or not ((p->>'id')::uuid = any(m.investigated))));
  end if;

  v := jsonb_build_object(
    'id', m.id, 'phase', m.phase, 'n', m.n, 'host_id', m.host_id, 'me', me, 'my_role', my_role,
    'players', pub_players, 'allies', allies,
    'enacted_h', m.enacted_h, 'enacted_r', m.enacted_r, 'tracker', m.tracker,
    'president', m.president, 'chancellor', m.chancellor,
    'last_president', m.last_president, 'last_chancellor', m.last_chancellor,
    'powers', to_jsonb(private.se_powers(m.n)), 'veto_unlocked', m.veto_unlocked, 'veto_denied', m.veto_denied,
    'deck_count', coalesce(array_length(m.deck, 1), 0), 'discard_count', coalesce(array_length(m.discard, 1), 0),
    'votes_in', (select count(*) from jsonb_object_keys(m.votes)), 'alive', alive,
    'last_vote', m.last_vote, 'log', m.log, 'winner', m.winner, 'win_reason', m.win_reason,
    'eligible', eligible, 'updated_at', m.updated_at,
    'hand', case when m.phase = 'president' and me = m.president then to_jsonb(m.hand)
                 when m.phase in ('chancellor', 'veto') and me = m.chancellor then to_jsonb(m.c_hand) else null end,
    'peek', case when m.phase = 'peek' and me = m.president then to_jsonb(m.peek) else null end,
    'investigation', case when m.phase = 'investigate_result' and me = m.president then m.investigation else null end
  );
  return v;
end $$;


ALTER FUNCTION "private"."speakeasy_view_for"("m" "public"."speakeasy_matches", "uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."unseen_count"("p_user" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select (
      (select count(*) from dm_messages   where recipient_id = p_user and read_at is null)
    + (select count(*) from invites       where recipient_id = p_user and status = 'pending')
    + (select count(*) from event_members where profile_id   = p_user and status = 'pending')
    + (select count(*) from friendships   where addressee_id = p_user and status = 'pending')
  )::int;
$$;


ALTER FUNCTION "private"."unseen_count"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."venue_find_or_create"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_country" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "private"."venue_find_or_create"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_country" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_comment"("p_post_id" "uuid", "p_body" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_id uuid; v_clean text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not can_see_post(p_post_id) then raise exception 'not allowed'; end if;
  v_clean := left(btrim(p_body), 500);
  if v_clean = '' then raise exception 'empty'; end if;
  insert into post_comments(post_id, author_id, body) values (p_post_id, auth.uid(), v_clean)
    returning id into v_id;
  return v_id;
end; $$;


ALTER FUNCTION "public"."add_comment"("p_post_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_app_feedback"() RETURNS TABLE("id" "uuid", "user_id" "uuid", "name" "text", "username" "text", "message" "text", "build" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select f.id, f.user_id, p.name, p.username, f.message, f.build, f.created_at
    from app_feedback f join profiles p on p.id = f.user_id
   where private.is_app_admin()
   order by f.created_at desc
   limit 300;
$$;


ALTER FUNCTION "public"."admin_app_feedback"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_apply_mapkit_ids"("p_pairs" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_n integer := 0;
begin
  -- auth.uid() is null only for server-side callers; EXECUTE is revoked from
  -- anon below, so this can't be reached without an admin session or a key.
  if auth.uid() is not null
     and not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;

  with raw as (
    select (e->>'id')::uuid as vid,
           nullif(e->>'mapkit_id','') as mk,
           (e->>'apple_lat')::double precision as alat,
           (e->>'apple_lon')::double precision as alon
    from jsonb_array_elements(p_pairs) e
  ),
  pairs as (
    select distinct on (r.mk) r.*
    from raw r
    join venues v on v.id = r.vid
    where r.mk is not null
      and not exists (select 1 from venues o
                       where o.mapkit_id = r.mk and o.id <> r.vid)
    order by r.mk, v.created_at, r.vid
  )
  update venues v
     set mapkit_id = p.mk,
         mapkit_checked_at = now(),
         -- Apple's coordinate is trusted only for hand-seeded rows; OSM
         -- geometry is surveyed and generally better.
         lat = case when v.source in ('curated','user') and p.alat is not null
                    then p.alat else v.lat end,
         lon = case when v.source in ('curated','user') and p.alon is not null
                    then p.alon else v.lon end
  from pairs p
  where v.id = p.vid;

  get diagnostics v_n = row_count;
  return v_n;
end $$;


ALTER FUNCTION "public"."admin_apply_mapkit_ids"("p_pairs" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_business_queue"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  return jsonb_build_object(
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'status', b.status, 'org_number', b.org_number,
        'contact_email', b.contact_email, 'contact_phone', b.contact_phone,
        'venue_name', v.name, 'venue_city', v.city, 'venue_country', v.country,
        'owner_name', p.name, 'owner_username', p.username, 'created_at', b.created_at, 'admin_note', b.admin_note,
        'tier', private.biz_tier(b.id), 'tier_expires_at', b.tier_expires_at,
        'followers', (select count(*) from business_follows f where f.business_id = b.id)
      ) order by (b.status = 'pending') desc, b.created_at desc)
      from businesses b join venues v on v.id = b.venue_id left join profiles p on p.id = b.owner_id
      where b.status in ('pending','approved','suspended')
    ), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'kind', o.kind, 'status', o.status, 'paid', o.paid, 'amount_sek', o.amount_sek,
        'product_id', o.product_id, 'quantity', o.quantity, 'apple_transaction_id', o.apple_transaction_id, 'paid_at', o.paid_at,
        'detail', o.detail, 'created_at', o.created_at, 'business_name', b.name,
        'venue_name', v.name, 'venue_city', v.city,
        'title', coalesce(pu.title, co.title), 'body', pu.body,
        'image_url', co.image_url, 'billboard_image_url', null,
        'placement', co.placement, 'send_at', pu.send_at,
        'audience_cap', coalesce(pu.audience_cap, c.audience_cap), 'reject_reason', o.reject_reason
      ) order by (o.status = 'pending') desc, o.created_at desc)
      from business_orders o
      join businesses b on b.id = o.business_id join venues v on v.id = b.venue_id
      left join business_cards c on c.id = o.card_id left join venue_offers co on co.id = c.offer_id
      left join business_pushes pu on pu.id = o.push_id
      where o.kind in ('card','push')
        and (o.status = 'pending'
          or (o.status = 'approved' and (not o.paid or o.created_at > now() - interval '30 days')))
    ), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'kind', kind, 'quantity', quantity,
                                                              'amount_sek', amount_sek, 'label', label) order by sort)
                          from business_products), '[]'::jsonb),
    'limits', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'value', value, 'label', label) order by key) from business_limits), '[]'::jsonb)
  );
end $$;


ALTER FUNCTION "public"."admin_business_queue"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_business_set_status"("p_business" "uuid", "p_status" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  if p_status not in ('approved','rejected','suspended') then raise exception 'bad_status'; end if;
  update businesses set status = p_status, reviewed_at = now(), reviewed_by = auth.uid(),
         admin_note = coalesce(nullif(trim(coalesce(p_note,'')),''), admin_note)
   where id = p_business;
  perform private.business_sync_presence(p_business);
end $$;


ALTER FUNCTION "public"."admin_business_set_status"("p_business" "uuid", "p_status" "text", "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_campaigns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "placement" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "cta_text" "text",
    "image_url" "text",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "is_active" boolean DEFAULT true NOT NULL,
    "approved" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "venue_campaigns_placement_check" CHECK (("placement" = ANY (ARRAY['poster'::"text", 'billboard'::"text", 'interstitial'::"text", 'push'::"text"])))
);


ALTER TABLE "public"."venue_campaigns" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_campaign"("p_venue" "uuid", "p_placement" "text", "p_title" "text", "p_body" "text", "p_cta" "text", "p_image_url" "text", "p_starts" timestamp with time zone, "p_ends" timestamp with time zone) RETURNS "public"."venue_campaigns"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_create_campaign"("p_venue" "uuid", "p_placement" "text", "p_title" "text", "p_body" "text", "p_cta" "text", "p_image_url" "text", "p_starts" timestamp with time zone, "p_ends" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_offer"("p_name" "text", "p_address" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_lat" double precision DEFAULT 0, "p_lon" double precision DEFAULT 0, "p_external_id" "text" DEFAULT NULL::"text", "p_kind" "text" DEFAULT 'price'::"text", "p_title" "text" DEFAULT ''::"text", "p_description" "text" DEFAULT NULL::"text", "p_fine_print" "text" DEFAULT NULL::"text", "p_redeem" "text" DEFAULT 'show'::"text", "p_code" "text" DEFAULT NULL::"text", "p_starts_at" timestamp with time zone DEFAULT "now"(), "p_ends_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_active_days" integer[] DEFAULT NULL::integer[], "p_start_minute" integer DEFAULT NULL::integer, "p_end_minute" integer DEFAULT NULL::integer, "p_placement" "text" DEFAULT 'pin'::"text", "p_image_url" "text" DEFAULT NULL::"text", "p_billboard_image_url" "text" DEFAULT NULL::"text", "p_interstitial" boolean DEFAULT false, "p_show_on_valid_only" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."admin_create_offer"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_redeem" "text", "p_code" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_campaign"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  delete from venue_campaigns where id = p_id;
end $$;


ALTER FUNCTION "public"."admin_delete_campaign"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_offer"("p_offer_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  delete from venue_offers where id = p_offer_id;
end; $$;


ALTER FUNCTION "public"."admin_delete_offer"("p_offer_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_campaigns"() RETURNS TABLE("id" "uuid", "venue_id" "uuid", "venue_name" "text", "venue_tier" "text", "placement" "text", "title" "text", "body" "text", "cta_text" "text", "image_url" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "is_active" boolean, "impressions" bigint, "taps" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_list_campaigns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_offers"() RETURNS TABLE("id" "uuid", "venue_id" "uuid", "venue_name" "text", "lat" double precision, "lon" double precision, "kind" "text", "title" "text", "description" "text", "fine_print" "text", "redeem" "text", "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "active_days" integer[], "start_minute" integer, "end_minute" integer, "is_active" boolean, "approved" boolean, "created_at" timestamp with time zone, "placement" "text", "image_url" "text", "billboard_image_url" "text", "interstitial" boolean, "show_on_valid_only" boolean, "impressions" bigint, "taps" bigint, "week_impressions" bigint, "week_taps" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_list_offers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_order_decide"("p_order" "uuid", "p_action" "text", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  if p_action = 'approve' then
    update business_orders set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid(), reject_reason = null
     where id = p_order and status in ('pending','approved');
  elsif p_action = 'paid' then
    update business_orders set paid = true, status = 'approved', reviewed_at = now(), reviewed_by = auth.uid(), reject_reason = null
     where id = p_order and status in ('pending','approved');
  elsif p_action = 'unpaid' then
    update business_orders set paid = false where id = p_order;
  elsif p_action = 'reject' then
    update business_orders set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
           reject_reason = nullif(trim(coalesce(p_reason,'')),'')
     where id = p_order and status in ('pending','approved');
  else
    raise exception 'bad_action';
  end if;
  perform private.business_order_sync(p_order);
end $$;


ALTER FUNCTION "public"."admin_order_decide"("p_order" "uuid", "p_action" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_report_resolve"("p_report" "uuid", "p_action" "text" DEFAULT 'no action'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  update reports
     set resolved_at = now(), resolved_by = auth.uid(),
         action_taken = coalesce(nullif(trim(p_action), ''), 'no action')
   where id = p_report and resolved_at is null;
end $$;


ALTER FUNCTION "public"."admin_report_resolve"("p_report" "uuid", "p_action" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reports"("p_include_resolved" boolean DEFAULT false) RETURNS TABLE("id" "uuid", "created_at" timestamp with time zone, "reporter_id" "uuid", "reporter_name" "text", "reporter_username" "text", "target_kind" "text", "target_id" "uuid", "target_user_id" "uuid", "target_name" "text", "target_username" "text", "reason" "text", "content_caption" "text", "content_ref" "text", "content_created_at" timestamp with time zone, "content_deleted_at" timestamp with time zone, "content_gone" boolean, "resolved_at" timestamp with time zone, "action_taken" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select r.id, r.created_at,
         r.reporter_id, rp.name, rp.username,
         r.target_kind, r.target_id,
         r.target_user_id, tp.name, tp.username,
         r.reason,
         case r.target_kind when 'post' then po.caption    when 'story' then ls.caption      end,
         case r.target_kind when 'post' then po.cover_url  when 'story' then ls.storage_path end,
         case r.target_kind when 'post' then po.created_at when 'story' then ls.created_at   end,
         case r.target_kind when 'post' then po.deleted_at when 'story' then ls.deleted_at   end,
         r.target_kind in ('post','story') and po.id is null and ls.id is null,
         r.resolved_at, r.action_taken
    from reports r
    join profiles rp on rp.id = r.reporter_id
    left join profiles tp on tp.id = r.target_user_id
    left join posts po on r.target_kind = 'post'  and po.id = r.target_id
    left join live_stories ls on r.target_kind = 'story' and ls.id = r.target_id
   where exists (select 1 from app_admins where user_id = auth.uid())
     and (p_include_resolved or r.resolved_at is null)
   order by r.created_at desc
   limit 500;
$$;


ALTER FUNCTION "public"."admin_reports"("p_include_resolved" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_restore"("p_kind" "text", "p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_kind = 'post' then
    update posts set deleted_at = null where id = p_id;
  elsif p_kind = 'story' then
    update live_stories set deleted_at = null where id = p_id;
  else
    raise exception 'bad_kind';
  end if;
end $$;


ALTER FUNCTION "public"."admin_restore"("p_kind" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_send_announcement"("p_title" "text", "p_body" "text", "p_dry_run" boolean DEFAULT true) RETURNS TABLE("recipients" integer, "dry_run" boolean, "sample" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_count integer;
  v_sample text;
  v_id uuid;
begin
  -- auth.uid() is null only for server-side callers (service_role); EXECUTE is
  -- revoked from anon below so this cannot be reached without a key.
  if auth.uid() is not null
     and not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;

  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_body), '') = '' then
    raise exception 'title_and_body_required';
  end if;

  select count(*), string_agg(username, ', ')
    into v_count, v_sample
  from (select username from profiles order by created_at limit 5) s;

  select count(*) into v_count from profiles;

  if p_dry_run then
    return query select v_count, true, v_sample;
    return;
  end if;

  insert into announcements (title, body, sent_by, recipients)
  values (p_title, p_body, auth.uid(), v_count)
  returning id into v_id;

  perform private.notify_push(
            p.id, p_title, p_body,
            jsonb_build_object('type', 'announcement', 'announcement_id', v_id))
  from profiles p;

  return query select v_count, false, v_sample;
end $$;


ALTER FUNCTION "public"."admin_send_announcement"("p_title" "text", "p_body" "text", "p_dry_run" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_business_limit"("p_key" "text", "p_value" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  update business_limits set value = greatest(0, p_value) where key = p_key;
end $$;


ALTER FUNCTION "public"."admin_set_business_limit"("p_key" "text", "p_value" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_business_product_price"("p_product_id" "text", "p_amount" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  update business_products set amount_sek = greatest(0, p_amount) where product_id = p_product_id;
end $$;


ALTER FUNCTION "public"."admin_set_business_product_price"("p_product_id" "text", "p_amount" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_campaign_active"("p_id" "uuid", "p_active" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  update venue_campaigns set is_active = p_active where id = p_id;
end $$;


ALTER FUNCTION "public"."admin_set_campaign_active"("p_id" "uuid", "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_venue_sun"("p_venue" "uuid", "p_mode" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_h smallint[];
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;

  if p_mode = 'clear' then
    update venue_sun
       set override_horizon = null, override_note = null, override_at = null
     where venue_id = p_venue;
    return;
  end if;

  v_h := case p_mode
    -- 89.9° blocked in every direction: the sun never clears it, so the venue
    -- reads as shade all day at any latitude and season.
    when 'no_sun'   then array_fill(899::smallint, array[72])
    -- Nothing blocking at all: a rooftop, a pier, an open square.
    when 'open_sky' then array_fill(0::smallint, array[72])
    else null
  end;
  if v_h is null then raise exception 'bad_mode'; end if;

  update venue_sun
     set override_horizon = v_h,
         override_note = p_note,
         override_at = now()
   where venue_id = p_venue;
end $$;


ALTER FUNCTION "public"."admin_set_venue_sun"("p_venue" "uuid", "p_mode" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_venue_tier"("p_venue" "uuid", "p_tier" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if p_tier not in ('none','pin','poster','billboard') then
    raise exception 'bad_tier';
  end if;
  update venues set tier = p_tier where id = p_venue;
end $$;


ALTER FUNCTION "public"."admin_set_venue_tier"("p_venue" "uuid", "p_tier" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_takedown"("p_kind" "text", "p_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_kind = 'post' then
    update posts set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind = 'story' then
    update live_stories set deleted_at = now() where id = p_id and deleted_at is null;
  else
    raise exception 'bad_kind';
  end if;
  update reports
     set resolved_at = now(), resolved_by = auth.uid(),
         action_taken = coalesce(nullif(trim(p_reason), ''), 'content removed')
   where target_kind = p_kind and target_id = p_id and resolved_at is null;
end $$;


ALTER FUNCTION "public"."admin_takedown"("p_kind" "text", "p_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_offer"("p_offer_id" "uuid", "p_kind" "text" DEFAULT 'price'::"text", "p_title" "text" DEFAULT ''::"text", "p_description" "text" DEFAULT NULL::"text", "p_fine_print" "text" DEFAULT NULL::"text", "p_starts_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_ends_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_active_days" integer[] DEFAULT NULL::integer[], "p_start_minute" integer DEFAULT NULL::integer, "p_end_minute" integer DEFAULT NULL::integer, "p_placement" "text" DEFAULT 'pin'::"text", "p_image_url" "text" DEFAULT NULL::"text", "p_billboard_image_url" "text" DEFAULT NULL::"text", "p_interstitial" boolean DEFAULT false, "p_show_on_valid_only" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_update_offer"("p_offer_id" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_venue_requests"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if not private.is_app_admin() then raise exception 'not_admin'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'venue_id', v.id, 'name', v.name, 'city', v.city, 'country', v.country, 'address', v.address,
      'asks', t.n, 'last_at', t.last_at,
      'on_sejdel', exists (select 1 from businesses b where b.venue_id = v.id and b.status = 'approved' and private.biz_tier(b.id) <> 'none')
    ) order by t.n desc, t.last_at desc)
    from (select venue_id, count(*) as n, max(created_at) as last_at from venue_requests group by venue_id) t
    join venues v on v.id = t.venue_id
  ), '[]'::jsonb);
end $$;


ALTER FUNCTION "public"."admin_venue_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agreed_facade_bearing"("p_venue" "uuid") RETURNS smallint
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case when count(*) = 0 then null else
    ((degrees(atan2(sum(sin(radians(bearing))), sum(cos(radians(bearing)))))::int % 360) + 360) % 360
  end::smallint
  from venue_sun_facade_reports where venue_id = p_venue;
$$;


ALTER FUNCTION "public"."agreed_facade_bearing"("p_venue" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."app_feedback_add"("p_message" "text", "p_build" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if coalesce(trim(p_message), '') = '' then raise exception 'empty'; end if;
  insert into app_feedback (user_id, message, build) values (auth.uid(), left(trim(p_message), 2000), left(p_build, 40));
end $$;


ALTER FUNCTION "public"."app_feedback_add"("p_message" "text", "p_build" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."appstore_apply"("p_fact" "jsonb", "p_status" integer, "p_paid" boolean, "p_notification" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."appstore_apply"("p_fact" "jsonb", "p_status" integer, "p_paid" boolean, "p_notification" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_recalc_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events
     set supplies = coalesce(p_supplies, '{}'::jsonb)
   where id = p_event
     and plan_mode = 'calc'
     and exists (
       select 1 from event_members m
       where m.event_id = p_event
         and m.profile_id = auth.uid()
         and m.status = 'going'
     );
end; $$;


ALTER FUNCTION "public"."auto_recalc_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision DEFAULT 12) RETURNS TABLE("venues" bigint, "priced" bigint, "outdoor" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select count(*),
           count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id)),
           count(*) filter (where v.outdoor_seating = true)
    from venues v
    where abs(v.lat - p_lat) <= p_km / 111.0
      and abs(v.lon - p_lon) <= p_km / (111.0 * greatest(0.2, cos(radians(p_lat))));
end $$;


ALTER FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."beer_prices_normalize_serving"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if new.serving_raw is null then
    new.serving_raw := new.serving;
  end if;
  new.serving := public.normalize_beer_serving(new.serving);
  return new;
end;
$$;


ALTER FUNCTION "public"."beer_prices_normalize_serving"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_user"("p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_user = auth.uid() then raise exception 'cannot block yourself'; end if;
  insert into blocks (blocker_id, blocked_id) values (auth.uid(), p_user)
    on conflict do nothing;
  delete from friendships
    where (requester_id = auth.uid() and addressee_id = p_user)
       or (requester_id = p_user and addressee_id = auth.uid());
  delete from invites
    where (sender_id = auth.uid() and recipient_id = p_user)
       or (sender_id = p_user and recipient_id = auth.uid());
end; $$;


ALTER FUNCTION "public"."block_user"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."boosts_live"() RETURNS TABLE("id" "uuid", "business_id" "uuid", "business_name" "text", "username" "text", "logo_url" "text", "venue_id" "uuid", "post_id" "uuid", "image_url" "text", "image_ratio" real, "caption" "text", "event_at" timestamp with time zone, "offer_id" "uuid", "goal_views" integer, "views" integer, "created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select bo.id, b.id, b.name, b.username, b.logo_url, b.venue_id, p.id,
         p.image_url, p.image_ratio, p.caption, p.event_at, p.offer_id,
         bo.goal_views, bo.views, bo.created_at
  from business_boosts bo
  join business_posts p on p.id = bo.post_id and p.deleted_at is null
  join businesses b on b.id = bo.business_id and b.status = 'approved'
  where bo.status = 'live'
$$;


ALTER FUNCTION "public"."boosts_live"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_campaign_stats"("p_campaign" "uuid", "p_impressions" integer, "p_taps" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_imp integer := least(greatest(coalesce(p_impressions,0),0),20);
        v_tap integer := least(greatest(coalesce(p_taps,0),0),20);
begin
  if p_campaign is null then return; end if;
  insert into campaign_stats (campaign_id, day, impressions, taps)
  values (p_campaign, now()::date, v_imp, v_tap)
  on conflict (campaign_id, day) do update
    set impressions = campaign_stats.impressions + excluded.impressions,
        taps        = campaign_stats.taps        + excluded.taps;
  update business_boosts
     set views = views + v_imp, taps = taps + v_tap,
         status  = case when views + v_imp >= goal_views then 'done' else status end,
         done_at = case when views + v_imp >= goal_views then now() else done_at end
   where id = p_campaign and status = 'live';
end $$;


ALTER FUNCTION "public"."bump_campaign_stats"("p_campaign" "uuid", "p_impressions" integer, "p_taps" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_boost_paid"("p_boost" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text" DEFAULT NULL::"text", "p_jws" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."business_boost_paid"("p_boost" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_by_username"("p_username" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select b.id from businesses b
  where b.username = lower(trim(p_username)) and b.status = 'approved' and private.biz_tier(b.id) <> 'none'
  limit 1
$$;


ALTER FUNCTION "public"."business_by_username"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_cancel_boost"("p_boost" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare bo public.business_boosts; b public.businesses;
begin
  select * into bo from business_boosts where id = p_boost;
  if bo.id is null then raise exception 'no_boost'; end if;
  b := private.business_for_owner(bo.business_id, false);
  if bo.status <> 'pending' then raise exception 'boost_not_pending'; end if;
  update business_boosts set status = 'cancelled' where id = bo.id;
end $$;


ALTER FUNCTION "public"."business_cancel_boost"("p_boost" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_cancel_event"("p_event" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare e public.business_events; b public.businesses;
begin
  select * into e from business_events where id = p_event;
  if e.id is null then raise exception 'no_event'; end if;
  b := private.business_for_owner(e.business_id, false);
  update business_events set cancelled_at = now() where id = e.id;
end $$;


ALTER FUNCTION "public"."business_cancel_event"("p_event" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_cancel_order"("p_order" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare ord public.business_orders; b public.businesses;
begin
  select * into ord from business_orders where id = p_order;
  if ord.id is null then raise exception 'no_order'; end if;
  b := private.business_for_owner(ord.business_id, false);
  if ord.status <> 'pending' then raise exception 'not_pending'; end if;
  update business_orders set status = 'cancelled', reviewed_at = now() where id = ord.id;
  if ord.offer_id is not null then update venue_offers set is_active = false where id = ord.offer_id; end if;
  if ord.card_id  is not null then update business_cards  set status = 'cancelled' where id = ord.card_id; end if;
  if ord.push_id  is not null then update business_pushes set status = 'cancelled' where id = ord.push_id; end if;
end $$;


ALTER FUNCTION "public"."business_cancel_order"("p_order" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_create_boost"("p_post" "uuid", "p_product_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."business_create_boost"("p_post" "uuid", "p_product_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_create_deal"("p_business" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text" DEFAULT NULL::"text", "p_fine_print" "text" DEFAULT NULL::"text", "p_starts_at" timestamp with time zone DEFAULT "now"(), "p_ends_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_active_days" integer[] DEFAULT NULL::integer[], "p_start_minute" integer DEFAULT NULL::integer, "p_end_minute" integer DEFAULT NULL::integer, "p_image_url" "text" DEFAULT NULL::"text", "p_show_on_valid_only" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."business_create_deal"("p_business" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_image_url" "text", "p_show_on_valid_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_create_event"("p_business" "uuid", "p_title" "text", "p_starts_at" timestamp with time zone, "p_image_url" "text" DEFAULT NULL::"text", "p_image_ratio" real DEFAULT 1) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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
    perform private.notify_push(f.user_id, b.name, trim(p_title) || ' ¬∑ ' || v_when,
              jsonb_build_object('type', 'business_event', 'business_id', b.id, 'event_id', v_id))
       from business_follows f where f.business_id = b.id;
  end if;
  return v_id;
end $$;


ALTER FUNCTION "public"."business_create_event"("p_business" "uuid", "p_title" "text", "p_starts_at" timestamp with time zone, "p_image_url" "text", "p_image_ratio" real) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_create_post"("p_business" "uuid", "p_image_urls" "text"[], "p_image_ratio" real DEFAULT 1, "p_caption" "text" DEFAULT NULL::"text", "p_event_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_offer" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v_tier text; v_post uuid; n integer;
begin
  b := private.business_for_owner(p_business, true);
  v_tier := private.biz_tier(b.id);
  if v_tier = 'none' then raise exception 'subscription_required'; end if;
  n := coalesce(array_length(p_image_urls, 1), 0);
  if n = 0 then raise exception 'image_required'; end if;
  if n > 1 and v_tier <> 'plus' then raise exception 'plus_required'; end if;
  if n > 10 then raise exception 'too_many_images'; end if;
  if length(coalesce(p_caption, '')) > 300 then raise exception 'too_long'; end if;
  if p_offer is not null and not exists (select 1 from venue_offers where id = p_offer and business_id = b.id) then
    raise exception 'no_offer';
  end if;
  insert into business_posts (business_id, image_url, image_urls, image_ratio, caption, event_at, offer_id)
  values (b.id, p_image_urls[1], p_image_urls, least(1.91, greatest(0.8, coalesce(p_image_ratio, 1))),
          nullif(trim(coalesce(p_caption, '')), ''), p_event_at, p_offer)
  returning id into v_post;
  return v_post;
end $$;


ALTER FUNCTION "public"."business_create_post"("p_business" "uuid", "p_image_urls" "text"[], "p_image_ratio" real, "p_caption" "text", "p_event_at" timestamp with time zone, "p_offer" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_delete_post"("p_post" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare p public.business_posts; b public.businesses;
begin
  select * into p from business_posts where id = p_post;
  if p.id is null then raise exception 'no_post'; end if;
  b := private.business_for_owner(p.business_id, false);
  update business_posts set deleted_at = now() where id = p.id;
  update business_boosts set status = 'cancelled' where post_id = p.id and status in ('pending','live');
end $$;


ALTER FUNCTION "public"."business_delete_post"("p_post" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_end_deal"("p_offer" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare o public.venue_offers; b public.businesses;
begin
  select * into o from venue_offers where id = p_offer;
  if o.id is null or o.business_id is null then raise exception 'no_offer'; end if;
  b := private.business_for_owner(o.business_id, false);
  update venue_offers set is_active = false where id = o.id;
end $$;


ALTER FUNCTION "public"."business_end_deal"("p_offer" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_events_upcoming"() RETURNS TABLE("id" "uuid", "business_id" "uuid", "business_name" "text", "username" "text", "logo_url" "text", "venue_id" "uuid", "venue_name" "text", "venue_city" "text", "title" "text", "starts_at" timestamp with time zone, "image_url" "text", "image_ratio" real)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select e.id, b.id, b.name, b.username, b.logo_url, v.id, v.name, v.city, e.title, e.starts_at, e.image_url, e.image_ratio
  from business_events e
  join businesses b on b.id = e.business_id and b.status = 'approved'
  join venues v on v.id = b.venue_id
  where e.cancelled_at is null
    and private.biz_tier(b.id) <> 'none'
    and e.starts_at > now() - interval '6 hours'
    and exists (select 1 from business_follows f where f.business_id = b.id and f.user_id = auth.uid())
  order by e.starts_at
  limit 50
$$;


ALTER FUNCTION "public"."business_events_upcoming"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_feed"("p_limit" integer DEFAULT 30, "p_before" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS TABLE("id" "uuid", "business_id" "uuid", "business_name" "text", "username" "text", "logo_url" "text", "venue_id" "uuid", "venue_name" "text", "venue_city" "text", "image_url" "text", "image_urls" "text"[], "image_ratio" real, "caption" "text", "event_at" timestamp with time zone, "offer_id" "uuid", "created_at" timestamp with time zone, "like_count" integer, "liked_by_me" boolean, "comment_count" integer, "views" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select p.id, b.id, b.name, b.username, b.logo_url, v.id, v.name, v.city,
         p.image_url, coalesce(p.image_urls, array[p.image_url]), p.image_ratio, p.caption, p.event_at, p.offer_id, p.created_at,
         (private.business_post_counts(p.id)->>'like_count')::int,
         (private.business_post_counts(p.id)->>'liked_by_me')::boolean,
         (private.business_post_counts(p.id)->>'comment_count')::int,
         (private.business_post_counts(p.id)->>'views')::int
  from business_posts p
  join businesses b on b.id = p.business_id
  join venues v on v.id = b.venue_id
  where p.deleted_at is null
    and b.status = 'approved' and private.biz_tier(b.id) <> 'none'
    and exists (select 1 from business_follows f where f.business_id = b.id and f.user_id = auth.uid())
    and (p_before is null or p.created_at < p_before)
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 50))
$$;


ALTER FUNCTION "public"."business_feed"("p_limit" integer, "p_before" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_mark_paid"("p_order" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text" DEFAULT NULL::"text", "p_jws" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."business_mark_paid"("p_order" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_mine"() RETURNS TABLE("id" "uuid", "name" "text", "username" "text", "status" "text", "admin_note" "text", "venue_id" "uuid", "venue_name" "text", "venue_city" "text", "venue_country" "text", "contact_email" "text", "created_at" timestamp with time zone, "tier" "text", "tier_expires_at" timestamp with time zone, "followers" bigint, "live_campaigns" bigint, "pending_orders" bigint, "unpaid_orders" bigint, "prior_name" "text", "prior_username" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select b.id, b.name, b.username, b.status, b.admin_note, b.venue_id, v.name, v.city, v.country, b.contact_email, b.created_at,
    private.biz_tier(b.id), b.tier_expires_at,
    (select count(*) from business_follows f where f.business_id = b.id),
    (select count(*) from venue_offers o where o.business_id = b.id and o.is_active and o.approved
        and (o.ends_at is null or o.ends_at > now())),
    (select count(*) from business_orders x where x.business_id = b.id and x.status = 'pending'),
    (select count(*) from business_orders x where x.business_id = b.id and x.status = 'approved' and not x.paid),
    b.prior_name, b.prior_username
  from businesses b join venues v on v.id = b.venue_id
  where b.owner_id = auth.uid() and b.status <> 'ended'
  order by b.created_at;
$$;


ALTER FUNCTION "public"."business_mine"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_overview"("p_business" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v public.venues; v_tier text; j jsonb;
begin
  b := private.business_for_owner(p_business, false);
  v_tier := private.biz_tier(b.id);
  select * into v from venues where id = b.venue_id;
  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', b.id, 'name', b.name, 'username', b.username, 'status', b.status, 'admin_note', b.admin_note,
      'venue_id', v.id, 'venue_name', v.name, 'venue_city', v.city, 'venue_country', v.country,
      'venue_lat', v.lat, 'venue_lon', v.lon, 'contact_email', b.contact_email,
      'tier', v_tier, 'tier_product_id', b.tier_product_id, 'tier_expires_at', b.tier_expires_at,
      'logo_url', b.logo_url, 'poster_url', b.poster_url, 'tagline', b.tagline,
      'followers', (select count(*) from business_follows f where f.business_id = b.id),
      'prior_name', b.prior_name, 'prior_username', b.prior_username,
      'qr_token', case when v_tier <> 'none' then v.qr_token end, 'list_days', b.list_days),
    'campaigns', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'kind', o.kind, 'title', o.title, 'description', o.description, 'fine_print', o.fine_print,
        'placement', o.placement, 'image_url', o.image_url, 'billboard_image_url', o.billboard_image_url,
        'starts_at', o.starts_at, 'ends_at', o.ends_at, 'active_days', o.active_days,
        'start_minute', o.start_minute, 'end_minute', o.end_minute, 'approved', o.approved,
        'live', (o.approved and o.is_active and (o.starts_at is null or o.starts_at <= now())
                 and (o.ends_at is null or o.ends_at > now())),
        'impressions', coalesce((select sum(s.impressions) from campaign_stats s where s.campaign_id = o.id), 0),
        'taps', coalesce((select sum(s.taps) from campaign_stats s where s.campaign_id = o.id), 0),
        'week_impressions', coalesce((select sum(s.impressions) from campaign_stats s
                                       where s.campaign_id = o.id and s.day >= current_date - 6), 0),
        'week_taps', coalesce((select sum(s.taps) from campaign_stats s
                                where s.campaign_id = o.id and s.day >= current_date - 6), 0)
      ) order by o.created_at desc)
      from venue_offers o
      where o.business_id = b.id and o.is_active and o.placement <> 'billboard'
        and (o.ends_at is null or o.ends_at > now() - interval '7 days')
    ), '[]'::jsonb),
    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'image_url', p.image_url, 'image_urls', coalesce(p.image_urls, array[p.image_url]),
        'image_ratio', p.image_ratio, 'caption', p.caption,
        'event_at', p.event_at, 'offer_id', p.offer_id, 'created_at', p.created_at,
        'boost', (select jsonb_build_object('id', bo.id, 'status', bo.status, 'product_id', bo.product_id,
                                            'goal_views', bo.goal_views, 'views', bo.views, 'taps', bo.taps)
                    from business_boosts bo where bo.post_id = p.id and bo.status <> 'cancelled'
                   order by bo.created_at desc limit 1)
      ) || private.business_post_counts(p.id) order by p.created_at desc)
      from business_posts p where p.business_id = b.id and p.deleted_at is null
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'starts_at', e.starts_at, 'image_url', e.image_url,
                                          'image_ratio', e.image_ratio, 'created_at', e.created_at) order by e.starts_at desc)
      from business_events e where e.business_id = b.id and e.cancelled_at is null
    ), '[]'::jsonb),
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'offer_id', c.offer_id, 'offer_title', o.title, 'audience_cap', c.audience_cap,
        'delivered', c.delivered,
        'tapped', (select count(*) from business_card_deliveries d where d.card_id = c.id and d.tapped),
        'status', c.status, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
        'order_id', ord.id, 'order_status', ord.status, 'paid', ord.paid, 'amount_sek', ord.amount_sek,
        'product_id', ord.product_id, 'quantity', ord.quantity, 'reject_reason', ord.reject_reason
      ) order by c.created_at desc)
      from business_cards c join venue_offers o on o.id = c.offer_id
      left join business_orders ord on ord.card_id = c.id
      where c.business_id = b.id and c.status <> 'cancelled'
    ), '[]'::jsonb),
    'pushes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'offer_id', p.offer_id, 'title', p.title, 'body', p.body, 'audience_cap', p.audience_cap,
        'send_at', p.send_at, 'status', p.status, 'recipient_count', p.recipient_count, 'sent_at', p.sent_at,
        'order_id', ord.id, 'order_status', ord.status, 'paid', ord.paid, 'amount_sek', ord.amount_sek,
        'product_id', ord.product_id, 'quantity', ord.quantity, 'reject_reason', ord.reject_reason
      ) order by p.created_at desc)
      from business_pushes p left join business_orders ord on ord.push_id = p.id
      where p.business_id = b.id and p.status <> 'cancelled'
    ), '[]'::jsonb),
    'next_push_at', (select max(sent_at) + make_interval(days => private.biz_limit('push_cooldown_days'))
                       from business_pushes where business_id = b.id and status = 'sent'),
    'push_pending', exists (select 1 from business_pushes where business_id = b.id and status in ('pending','approved')),
    'card_pending', exists (select 1 from business_cards where business_id = b.id and status in ('pending','live')),
    'products', coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'kind', kind, 'quantity', quantity,
                                                              'amount_sek', amount_sek, 'label', label) order by sort)
                          from business_products), '[]'::jsonb),
    'limits', (select jsonb_object_agg(key, value) from business_limits)
  ) into j;
  return j;
end $$;


ALTER FUNCTION "public"."business_overview"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_post_comment"("p_post" "uuid", "p_body" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not private.business_post_visible(p_post) then raise exception 'no_post'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty'; end if;
  if length(p_body) > 300 then raise exception 'too_long'; end if;
  insert into business_post_comments (post_id, user_id, body) values (p_post, v_uid, trim(p_body)) returning id into v_id;
  return v_id;
end $$;


ALTER FUNCTION "public"."business_post_comment"("p_post" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_post_comments"("p_post" "uuid") RETURNS TABLE("id" "uuid", "user_id" "uuid", "name" "text", "username" "text", "avatar_url" "text", "body" "text", "created_at" timestamp with time zone, "mine" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select c.id, c.user_id, pr.name, pr.username, pr.avatar_url, c.body, c.created_at, (c.user_id = auth.uid())
  from business_post_comments c join profiles pr on pr.id = c.user_id
  where c.post_id = p_post and c.deleted_at is null and private.business_post_visible(p_post)
  order by c.created_at
  limit 200
$$;


ALTER FUNCTION "public"."business_post_comments"("p_post" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_post_delete_comment"("p_comment" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare c public.business_post_comments; v_owner uuid;
begin
  select * into c from business_post_comments where id = p_comment;
  if c.id is null then return; end if;
  select b.owner_id into v_owner from business_posts p join businesses b on b.id = p.business_id where p.id = c.post_id;
  if c.user_id <> auth.uid() and v_owner <> auth.uid() then raise exception 'not_owner'; end if;
  update business_post_comments set deleted_at = now() where id = c.id;
end $$;


ALTER FUNCTION "public"."business_post_delete_comment"("p_comment" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_post_like"("p_post" "uuid", "p_on" boolean) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not private.business_post_visible(p_post) then raise exception 'no_post'; end if;
  if p_on then
    insert into business_post_likes (post_id, user_id) values (p_post, v_uid) on conflict do nothing;
  else
    delete from business_post_likes where post_id = p_post and user_id = v_uid;
  end if;
  return (select count(*) from business_post_likes where post_id = p_post);
end $$;


ALTER FUNCTION "public"."business_post_like"("p_post" "uuid", "p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_profile"("p_business" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v public.venues; v_tier text;
begin
  select * into b from businesses where id = p_business and status = 'approved';
  if b.id is null then raise exception 'no_business'; end if;
  v_tier := private.biz_tier(b.id);
  select * into v from venues where id = b.venue_id;
  return jsonb_build_object(
    'business', jsonb_build_object(
      'id', b.id, 'name', b.name, 'username', b.username, 'logo_url', b.logo_url,
      'poster_url', case when v_tier = 'plus' then b.poster_url end, 'tagline', b.tagline, 'tier', v_tier,
      'venue_id', v.id, 'venue_name', v.name, 'venue_city', v.city, 'venue_lat', v.lat, 'venue_lon', v.lon,
      'list_days', b.list_days, 'followers', (select count(*) from business_follows f where f.business_id = b.id),
      'account_id', (select p.id from profiles p where p.business_id = b.id limit 1), 'following', exists (select 1 from business_follows f where f.business_id = b.id and f.user_id = auth.uid())),
    'posts', coalesce((
      select jsonb_agg((jsonb_build_object(
        'id', p.id, 'image_url', p.image_url, 'image_urls', coalesce(p.image_urls, array[p.image_url]),
        'image_ratio', p.image_ratio, 'caption', p.caption,
        'event_at', p.event_at, 'offer_id', p.offer_id, 'created_at', p.created_at
      ) || private.business_post_counts(p.id)) order by p.created_at desc)
      from business_posts p where p.business_id = b.id and p.deleted_at is null and v_tier <> 'none'), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'starts_at', e.starts_at, 'image_url', e.image_url,
                                          'image_ratio', e.image_ratio) order by e.starts_at)
      from business_events e where e.business_id = b.id and e.cancelled_at is null and e.starts_at > now() - interval '6 hours'
        and v_tier <> 'none'), '[]'::jsonb),
    'deals', coalesce((
      select jsonb_agg(to_jsonb(o) order by o.created_at desc)
      from venue_offers o
      where o.business_id = b.id and o.is_active and o.approved
        and (o.starts_at is null or o.starts_at <= now()) and (o.ends_at is null or o.ends_at > now())), '[]'::jsonb)
  );
end $$;


ALTER FUNCTION "public"."business_profile"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_profiles_public"() RETURNS TABLE("id" "uuid", "venue_id" "uuid", "name" "text", "username" "text", "logo_url" "text", "poster_url" "text", "tagline" "text", "tier" "text", "followers" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select b.id, b.venue_id, b.name, b.username, b.logo_url,
         case when private.biz_tier(b.id) = 'plus' then b.poster_url end,
         b.tagline, private.biz_tier(b.id),
         (select count(*) from business_follows f where f.business_id = b.id)::int
  from businesses b
  where b.status = 'approved' and private.biz_tier(b.id) <> 'none'
$$;


ALTER FUNCTION "public"."business_profiles_public"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_qr_token"("p_business" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses;
begin
  b := private.business_for_owner(p_business, true);
  if private.biz_tier(b.id) = 'none' then raise exception 'subscription_required'; end if;
  return public.ensure_qr_token(b.venue_id);
end $$;


ALTER FUNCTION "public"."business_qr_token"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_register"("p_business_name" "text", "p_contact_email" "text", "p_contact_phone" "text" DEFAULT NULL::"text", "p_org_number" "text" DEFAULT NULL::"text", "p_venue_external_id" "text" DEFAULT NULL::"text", "p_venue_name" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_lat" double precision DEFAULT 0, "p_lon" double precision DEFAULT 0, "p_country" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $_$
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
end $_$;


ALTER FUNCTION "public"."business_register"("p_business_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_org_number" "text", "p_venue_external_id" "text", "p_venue_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_country" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_request_card"("p_business" "uuid", "p_offer" "uuid", "p_audience_cap" integer) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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
  values (b.id, 'card', v_card, prod.amount_sek, format('App-open card ¬∑ %s people ¬∑ "%s"', p_audience_cap, o.title),
          prod.product_id, 1)
  returning id into v_order;
  return v_order;
end $$;


ALTER FUNCTION "public"."business_request_card"("p_business" "uuid", "p_offer" "uuid", "p_audience_cap" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_request_push"("p_business" "uuid", "p_offer" "uuid", "p_title" "text", "p_body" "text", "p_audience_cap" integer, "p_send_at" timestamp with time zone) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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
          format('Push ¬∑ up to %s people ¬∑ %s', p_audience_cap, to_char(p_send_at at time zone v_tz, 'Dy DD Mon HH24:MI')),
          prod.product_id, 1)
  returning id into v_order;
  return v_order;
end $$;


ALTER FUNCTION "public"."business_request_push"("p_business" "uuid", "p_offer" "uuid", "p_title" "text", "p_body" "text", "p_audience_cap" integer, "p_send_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_set_list_days"("p_business" "uuid", "p_days" smallint[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from profiles p where p.id = auth.uid() and p.business_id = p_business) then raise exception 'not_yours'; end if;
  if p_days is null or exists (select 1 from unnest(p_days) d where d < 1 or d > 7) then raise exception 'bad_days'; end if;
  update businesses set list_days = (select coalesce(array_agg(distinct d order by d), '{}') from unnest(p_days) d) where id = p_business;
end $$;


ALTER FUNCTION "public"."business_set_list_days"("p_business" "uuid", "p_days" smallint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_sync_subscription"("p_business" "uuid", "p_product_id" "text", "p_original_transaction_id" "text" DEFAULT NULL::"text", "p_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_transaction_id" "text" DEFAULT NULL::"text", "p_jws" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses; v_tier text; v_was text; v_fact jsonb;
        v_product text; v_expires timestamptz; v_orig text; v_token uuid;
begin
  b := private.business_for_owner(p_business, false);
  v_was := private.biz_tier(b.id);

  v_fact := private.appstore_check(p_transaction_id);
  if v_fact is not null then
    v_product := v_fact->>'product_id';
    v_expires := nullif(v_fact->>'expires_at', '')::timestamptz;
    v_orig    := nullif(v_fact->>'original_transaction_id', '');
    begin v_token := nullif(v_fact->>'app_account_token', '')::uuid; exception when others then v_token := null; end;
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


ALTER FUNCTION "public"."business_sync_subscription"("p_business" "uuid", "p_product_id" "text", "p_original_transaction_id" "text", "p_expires_at" timestamp with time zone, "p_transaction_id" "text", "p_jws" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."business_update_profile"("p_business" "uuid", "p_logo_url" "text" DEFAULT NULL::"text", "p_poster_url" "text" DEFAULT NULL::"text", "p_tagline" "text" DEFAULT NULL::"text", "p_clear_logo" boolean DEFAULT false, "p_clear_poster" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare b public.businesses;
begin
  b := private.business_for_owner(p_business, true);
  if length(coalesce(p_tagline, '')) > 80 then raise exception 'too_long'; end if;
  update businesses
     set logo_url   = case when p_clear_logo then null else coalesce(p_logo_url, logo_url) end,
         poster_url = case when p_clear_poster then null else coalesce(p_poster_url, poster_url) end,
         tagline    = case when p_tagline is null then tagline else nullif(trim(p_tagline), '') end
   where id = b.id;
  if p_logo_url is not null then
    update profiles set avatar_url = p_logo_url where id = b.owner_id and business_id = b.id;
  end if;
  perform private.business_sync_presence(b.id);
end $$;


ALTER FUNCTION "public"."business_update_profile"("p_business" "uuid", "p_logo_url" "text", "p_poster_url" "text", "p_tagline" "text", "p_clear_logo" boolean, "p_clear_poster" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_see_post"("p_post_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from posts po
    where po.id = p_post_id
      and po.deleted_at is null
      and (
        po.author_id = auth.uid()
        or exists(select 1 from friendships f where f.status='accepted'
            and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
              or (f.requester_id=po.author_id and f.addressee_id=auth.uid())))
      )
  );
$$;


ALTER FUNCTION "public"."can_see_post"("p_post_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_event"("p_event" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_session uuid;
begin
  select e.live_session_id into v_session
    from events e
   where e.id = p_event and e.host_id = auth.uid();

  if v_session is not null then
    update sessions set active_live = false where id = v_session;
  end if;

  delete from events where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."cancel_event"("p_event" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."city_index"("p_country" "text") RETURNS TABLE("city" "text", "venues" bigint, "priced" bigint, "outdoor" bigint, "min_lat" double precision, "max_lat" double precision, "min_lon" double precision, "max_lon" double precision)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.city, count(*),
           count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id)),
           count(*) filter (where v.outdoor_seating = true),
           min(v.lat), max(v.lat), min(v.lon), max(v.lon)
    from venues v
    where v.country = upper(p_country) and v.city is not null
    group by v.city
    order by (count(*) filter (where exists
               (select 1 from beer_prices bp where bp.venue_id = v.id))
              + count(*) filter (where v.outdoor_seating = true)) desc,
             count(*) desc
    limit 15;
end $$;


ALTER FUNCTION "public"."city_index"("p_country" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_sponsored_card"("p_lat" double precision, "p_lon" double precision) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_uid uuid := auth.uid(); v_card uuid; o public.venue_offers; v public.venues; c public.business_cards;
begin
  if v_uid is null or p_lat is null or p_lon is null then return null; end if;
  if exists (select 1 from profiles where id = v_uid and sponsored_cards_opt_out) then return null; end if;
  if exists (select 1 from business_card_deliveries d where d.user_id = v_uid
               and d.delivered_at > now() - make_interval(hours => private.biz_limit('user_card_hours'))) then
    return null;
  end if;
  select bc.id into v_card
    from business_cards bc
    join venue_offers vo on vo.id = bc.offer_id
    join venues vv on vv.id = vo.venue_id
   where bc.status = 'live' and bc.delivered < bc.audience_cap
     and (bc.ends_at is null or bc.ends_at > now())
     and vo.is_active and vo.approved and vo.image_url is not null
     and (vo.starts_at is null or vo.starts_at <= now()) and (vo.ends_at is null or vo.ends_at > now())
     and public.haversine_m(p_lat, p_lon, vv.lat, vv.lon) <= private.biz_limit('radius_m')
     and not exists (select 1 from business_card_deliveries d where d.card_id = bc.id and d.user_id = v_uid)
   order by bc.created_at
   limit 1
   for update of bc skip locked;
  if v_card is null then return null; end if;
  insert into business_card_deliveries (card_id, user_id) values (v_card, v_uid) on conflict do nothing;
  update business_cards
     set delivered = delivered + 1,
         status = case when delivered + 1 >= audience_cap then 'done' else status end
   where id = v_card
  returning * into c;
  select * into o from venue_offers where id = c.offer_id;
  select * into v from venues where id = o.venue_id;
  return jsonb_build_object('card_id', c.id, 'offer', to_jsonb(o), 'venue', to_jsonb(v));
end $$;


ALTER FUNCTION "public"."claim_sponsored_card"("p_lat" double precision, "p_lon" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_my_contact_keys"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  delete from contact_keys where profile_id = auth.uid();
end $$;


ALTER FUNCTION "public"."clear_my_contact_keys"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."country_index"() RETURNS TABLE("country" "text", "venues" bigint, "priced" bigint, "outdoor" bigint, "min_lat" double precision, "max_lat" double precision, "min_lon" double precision, "max_lon" double precision)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.country, count(*),
           count(*) filter (where exists
             (select 1 from beer_prices bp where bp.venue_id = v.id)),
           count(*) filter (where v.outdoor_seating = true),
           min(v.lat), max(v.lat), min(v.lon), max(v.lon)
    from venues v
    where v.country is not null
    group by v.country
    order by count(*) desc;
end $$;


ALTER FUNCTION "public"."country_index"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_event"("p_title" "text", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_duration_hours" numeric, "p_nights" integer, "p_target_bac" numeric, "p_auto_live" boolean DEFAULT false) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  insert into events (host_id, title, kind, starts_at, duration_hours, nights, target_bac, auto_live)
  values (auth.uid(), p_title, p_kind, p_starts_at, p_duration_hours,
          coalesce(p_nights, 1), coalesce(p_target_bac, 0.08), coalesce(p_auto_live, false))
  returning id into v_id;

  insert into event_members (event_id, profile_id, status, responded_at)
  values (v_id, auth.uid(), 'going', now());

  return v_id;
end; $$;


ALTER FUNCTION "public"."create_event"("p_title" "text", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_duration_hours" numeric, "p_nights" integer, "p_target_bac" numeric, "p_auto_live" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_account_rows"("p_uid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_uid is null then raise exception 'bad_uid'; end if;
  -- Defense in depth: a JWT-bearing caller (auth.uid() set) may only delete
  -- itself. service_role/cron has a null auth.uid() and is trusted.
  if auth.uid() is not null and p_uid <> auth.uid() then
    raise exception 'forbidden';
  end if;
  -- FK-less or NO ACTION references that would survive (or block) the cascade
  update venue_push_log  set sent_by     = null where sent_by     = p_uid;
  update event_members   set invited_by  = null where invited_by  = p_uid;
  update businesses      set reviewed_by = null where reviewed_by = p_uid;
  update business_orders set reviewed_by = null where reviewed_by = p_uid;
  delete from dm_messages where sender_id = p_uid or recipient_id = p_uid;
  delete from events where host_id = p_uid;   -- members cascade with the event
  -- everything else: auth.users -> profiles -> the app, all ON DELETE CASCADE
  delete from auth.users where id = p_uid;
end $$;


ALTER FUNCTION "public"."delete_account_rows"("p_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_comment"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from post_comments c
   where c.id = p_id and (
     c.author_id = auth.uid()
     or exists(select 1 from posts po where po.id=c.post_id and po.author_id=auth.uid())
   );
end; $$;


ALTER FUNCTION "public"."delete_comment"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."disclaimer_ack"("p_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  update profiles
     set disclaimer_ack_at = case
           when disclaimer_ack_version is distinct from p_version then now()
           else coalesce(disclaimer_ack_at, now()) end,
         disclaimer_ack_version = p_version
   where id = auth.uid();
  return public.disclaimer_state();
end $$;


ALTER FUNCTION "public"."disclaimer_ack"("p_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."disclaimer_state"() RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object('ack_at', disclaimer_ack_at, 'version', disclaimer_ack_version)
    from profiles where id = auth.uid();
$$;


ALTER FUNCTION "public"."disclaimer_state"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dm_can_message"("p_other" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select auth.uid() is not null and p_other <> auth.uid() and (
    exists (select 1 from friendships f where f.status = 'accepted'
              and ((f.requester_id = auth.uid() and f.addressee_id = p_other)
                or (f.addressee_id = auth.uid() and f.requester_id = p_other)))
    or exists (select 1 from profiles p where p.id = p_other and p.business_id is not null)
    or exists (select 1 from profiles me join dm_messages d on d.recipient_id = me.id and d.sender_id = p_other
               where me.id = auth.uid() and me.business_id is not null)
  )
$$;


ALTER FUNCTION "public"."dm_can_message"("p_other" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dm_partners"("p_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url, 'business_id', p.business_id)), '[]'::jsonb)
  from profiles p
  where p.id = any(p_ids) and auth.uid() is not null and (
    p.id = auth.uid()
    or p.business_id is not null
    or exists (select 1 from dm_messages d where (d.sender_id = auth.uid() and d.recipient_id = p.id)
                                              or (d.recipient_id = auth.uid() and d.sender_id = p.id))
    or exists (select 1 from friendships f where f.status = 'accepted'
                 and ((f.requester_id = auth.uid() and f.addressee_id = p.id)
                   or (f.addressee_id = auth.uid() and f.requester_id = p.id)))
  )
$$;


ALTER FUNCTION "public"."dm_partners"("p_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."email_for_username"("p_username" "text") RETURNS "text"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  select u.email
  from auth.users u
  join profiles p on p.id = u.id
  where lower(p.username) = lower(trim(p_username))
  limit 1;
$$;


ALTER FUNCTION "public"."email_for_username"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_qr_token"("p_venue" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."ensure_qr_token"("p_venue" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."follow_business"("p_business" "uuid", "p_on" boolean) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."follow_business"("p_business" "uuid", "p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."friends_feed"("p_limit" integer DEFAULT 30, "p_before" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS TABLE("id" "uuid", "author_id" "uuid", "author_name" "text", "author_username" "text", "author_avatar" "text", "recap" "jsonb", "include_bac" boolean, "caption" "text", "cover_url" "text", "started_at" timestamp with time zone, "created_at" timestamp with time zone, "like_count" integer, "liked_by_me" boolean, "comment_count" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where po.deleted_at is null
    and (
      po.author_id = auth.uid()
      or exists (select 1 from friendships f where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
          or (f.requester_id=po.author_id and f.addressee_id=auth.uid())))
    )
    and po.created_at > now() - interval '7 days'
    and (p_before is null or po.created_at < p_before)
  order by po.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 50));
$$;


ALTER FUNCTION "public"."friends_feed"("p_limit" integer, "p_before" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."friends_live_pulse"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
  select case when auth.uid() is null then '[]'::jsonb
              else private.friends_live_pulse_for(auth.uid()) end;
$$;


ALTER FUNCTION "public"."friends_live_pulse"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."game_round_for_session"("p_session" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'id',             r.id,
    'host_id',        r.host_id,
    'kind',           r.kind,
    'spicy',          r.spicy,
    'revealed',       r.revealed,
    'player_count',   coalesce(array_length(r.player_ids, 1), 0),
    'imposter_count', coalesce(array_length(r.imps, 1), 0),
    'is_player',      auth.uid() = any (r.player_ids),
    'is_imposter',    auth.uid() = any (r.imps),
    'starter_id',     r.starter_id,
    'word',           case when auth.uid() = any (r.imps) and not r.revealed
                           then null else r.word end,
    'imposter_id',    case when r.revealed then r.imposter_id else null end,
    'imposter_ids',   case when r.revealed then to_jsonb(r.imps) else null end
  )
  from (
    select g.*, coalesce(nullif(g.imposter_ids, '{}'), array[g.imposter_id]) as imps
    from public.game_rounds g
    where g.session_id = p_session
      and public.is_session_member(p_session)
      and g.created_at > now() - interval '6 hours'
    order by g.created_at desc
    limit 1
  ) r;
$$;


ALTER FUNCTION "public"."game_round_for_session"("p_session" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grant_admin_by_email"("p_email" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_target uuid;
  v_name   text;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid() and is_owner) then
    raise exception 'only the owner can grant admin';
  end if;
  select u.id into v_target
  from auth.users u
  where lower(u.email) = lower(trim(p_email))
  limit 1;
  if v_target is null then
    return jsonb_build_object('ok', false, 'reason', 'no_user');
  end if;
  insert into app_admins (user_id, is_owner)
  values (v_target, false)
  on conflict (user_id) do nothing;
  select name into v_name from profiles where id = v_target;
  return jsonb_build_object('ok', true, 'name', coalesce(v_name, p_email));
end;
$$;


ALTER FUNCTION "public"."grant_admin_by_email"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."haversine_m"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  select 6371000 * 2 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lon2 - lon1) / 2), 2)
  )));
$$;


ALTER FUNCTION "public"."haversine_m"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invite_to_event"("p_event" "uuid", "p_recipients" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_recipient uuid;
begin
  if not exists (select 1 from events e where e.id = p_event and e.host_id = auth.uid()) then
    raise exception 'only the host can invite';
  end if;

  foreach v_recipient in array p_recipients loop
    if exists (
      select 1 from friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = v_recipient)
          or (f.addressee_id = auth.uid() and f.requester_id = v_recipient))
    ) then
      insert into event_members (event_id, profile_id, status, invited_by)
      values (p_event, v_recipient, 'pending', auth.uid())
      on conflict (event_id, profile_id) do update
        set status = case
              when event_members.status = 'declined' then 'pending'
              else event_members.status
            end,
            invited_by = excluded.invited_by;
    end if;
  end loop;
end; $$;


ALTER FUNCTION "public"."invite_to_event"("p_event" "uuid", "p_recipients" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_event_host"("p_event" "uuid", "p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from events e
    where e.id = p_event and e.host_id = p_user
  );
$$;


ALTER FUNCTION "public"."is_event_host"("p_event" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_event_member"("p_event" "uuid", "p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from event_members m
    where m.event_id = p_event and m.profile_id = p_user
  );
$$;


ALTER FUNCTION "public"."is_event_member"("p_event" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_session_member"("sid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.session_members
    where session_id = sid and profile_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_session_member"("sid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_session_by_code"("code" "text", "mode" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  sid uuid;
  uid uuid := auth.uid();
  joining_plan boolean := mode = 'plan';
  joining_live boolean := mode = 'live';
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if mode not in ('plan', 'live') then
    raise exception 'invalid mode: %', mode;
  end if;

  select id into sid from sessions
    where join_code = upper(code)
      and ((joining_plan and active_plan) or (joining_live and active_live))
    limit 1;

  if sid is null then
    raise exception 'no active session for code % in % mode', code, mode;
  end if;

  insert into session_members (session_id, profile_id, in_plan, in_live)
  values (sid, uid, joining_plan, joining_live)
  on conflict (session_id, profile_id) do update
    set in_plan = session_members.in_plan or excluded.in_plan,
        in_live = session_members.in_live or excluded.in_live;

  return sid;
end;
$$;


ALTER FUNCTION "public"."join_session_by_code"("code" "text", "mode" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leave_event"("p_event" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from event_members
   where event_id = p_event and profile_id = auth.uid()
     and not exists (select 1 from events e where e.id = p_event and e.host_id = auth.uid());
end; $$;


ALTER FUNCTION "public"."leave_event"("p_event" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_comments"("p_post_id" "uuid") RETURNS TABLE("id" "uuid", "author_id" "uuid", "author_name" "text", "author_username" "text", "author_avatar" "text", "body" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.id, c.author_id, pr.name, pr.username, pr.avatar_url, c.body, c.created_at
  from post_comments c join profiles pr on pr.id = c.author_id
  where c.post_id = p_post_id and can_see_post(p_post_id)
  order by c.created_at asc;
$$;


ALTER FUNCTION "public"."list_comments"("p_post_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_friends"() RETURNS TABLE("friendship_id" "uuid", "id" "uuid", "name" "text", "username" "text", "avatar_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return query
    select f.id, p.id, p.name, p.username, p.avatar_url
    from friendships f
    join profiles p on p.id = case when f.requester_id=auth.uid() then f.addressee_id else f.requester_id end
    where f.status='accepted' and (f.requester_id=auth.uid() or f.addressee_id=auth.uid())
    order by p.name;
end;
$$;


ALTER FUNCTION "public"."list_friends"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_guest_flag"("p_business" "uuid", "p_user" "uuid", "p_flag" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from profiles p where p.id = auth.uid() and p.business_id = p_business) then raise exception 'not_yours'; end if;
  if private.biz_tier(p_business) <> 'plus' then raise exception 'plus_required'; end if;
  if p_flag is null then
    delete from list_guest_flags where business_id = p_business and user_id = p_user;
  else
    if p_flag not in ('favorite', 'blocked') then raise exception 'bad_flag'; end if;
    insert into list_guest_flags (business_id, user_id, flag) values (p_business, p_user, p_flag)
    on conflict (business_id, user_id) do update set flag = excluded.flag, created_at = now();
  end if;
end $$;


ALTER FUNCTION "public"."list_guest_flag"("p_business" "uuid", "p_user" "uuid", "p_flag" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_guest_flags_for"("p_business" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', f.user_id, 'flag', f.flag, 'created_at', f.created_at,
    'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url,
    'last_name', (select r.full_name from list_requests r where r.business_id = f.business_id and r.user_id = f.user_id order by r.created_at desc limit 1),
    'instagram', (select r.instagram from list_requests r where r.business_id = f.business_id and r.user_id = f.user_id order by r.created_at desc limit 1)
  ) order by f.flag, p.name), '[]'::jsonb)
  from list_guest_flags f join profiles p on p.id = f.user_id
  where f.business_id = p_business
    and exists (select 1 from profiles me where me.id = auth.uid() and me.business_id = p_business)
$$;


ALTER FUNCTION "public"."list_guest_flags_for"("p_business" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_incoming_requests"() RETURNS TABLE("request_id" "uuid", "id" "uuid", "name" "text", "username" "text", "avatar_url" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  return query
    select f.id, p.id, p.name, p.username, p.avatar_url, f.created_at
    from friendships f
    join profiles p on p.id = f.requester_id
    where f.status='pending' and f.addressee_id=auth.uid()
    order by f.created_at desc;
end;
$$;


ALTER FUNCTION "public"."list_incoming_requests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_request_decide"("p_request" "uuid", "p_approve" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_me uuid := auth.uid(); r list_requests; v_status text;
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  select * into r from list_requests where id = p_request;
  if r.id is null then raise exception 'no_request'; end if;
  if not exists (select 1 from profiles p where p.id = v_me and p.business_id = r.business_id) then raise exception 'not_yours'; end if;
  v_status := case when p_approve then 'approved' else 'declined' end;
  if r.status = v_status then return; end if;
  update list_requests set status = v_status, decided_at = now() where id = r.id;
  perform private.list_request_reply(r.id);
end $$;


ALTER FUNCTION "public"."list_request_decide"("p_request" "uuid", "p_approve" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_request_send"("p_business" "uuid", "p_full_name" "text", "p_instagram" "text", "p_plus" integer, "p_night" "date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $_$
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
          format('üéü Get on the list ¬∑ %s ¬∑ %s +%s%s', to_char(p_night, 'Dy FMDD Mon'), v_name, p_plus,
                 case when v_insta is null then '' else ' ¬∑ @' || v_insta end), v_id);
  if v_status <> 'pending' then perform private.list_request_reply(v_id); end if;
  return v_id;
end $_$;


ALTER FUNCTION "public"."list_request_send"("p_business" "uuid", "p_full_name" "text", "p_instagram" "text", "p_plus" integer, "p_night" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_requests_for"("p_business" "uuid", "p_from" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'business_id', r.business_id, 'user_id', r.user_id, 'full_name', r.full_name, 'instagram', r.instagram,
    'plus_count', r.plus_count, 'night', r.night, 'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at,
    'user_name', p.name, 'user_username', p.username, 'user_avatar', p.avatar_url,
    'flag', (select f.flag from list_guest_flags f where f.business_id = r.business_id and f.user_id = r.user_id)
  ) order by r.night, (r.status <> 'pending'), r.created_at), '[]'::jsonb)
  from list_requests r join profiles p on p.id = r.user_id
  where r.business_id = p_business
    and exists (select 1 from profiles me where me.id = auth.uid() and me.business_id = p_business)
    and r.night >= coalesce(p_from, current_date - 1)
$$;


ALTER FUNCTION "public"."list_requests_for"("p_business" "uuid", "p_from" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_sip"("p_session" "uuid", "p_profile" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare uid uuid := auth.uid(); new_id uuid;
begin
  if uid is null then raise exception 'sign in'; end if;
  if not exists (select 1 from public.session_members where session_id = p_session and profile_id = uid) then
    raise exception 'not in this sesh';
  end if;
  if not exists (select 1 from public.session_members where session_id = p_session and profile_id = p_profile) then
    raise exception 'they are not in this sesh';
  end if;
  insert into public.session_drinks (session_id, profile_id, drink_name, volume_ml, abv, shared, live)
  values (p_session, p_profile, 'Sip', 16.5, 0.05, false, true)
  returning id into new_id;
  return new_id;
end $$;


ALTER FUNCTION "public"."log_sip"("p_session" "uuid", "p_profile" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_contacts"("p_hashes" "text"[]) RETURNS TABLE("id" "uuid", "name" "text", "username" "text", "avatar_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_hashes is null or array_length(p_hashes, 1) is null then return; end if;
  if array_length(p_hashes, 1) > 4000 then raise exception 'too_many'; end if;
  if not rate_limit_hit('contact_match', v_uid::text, 40, '1 hour') then
    raise exception 'rate_limited';
  end if;

  return query
    select distinct p.id, p.name, p.username, p.avatar_url
    from contact_keys k
    join profiles p on p.id = k.profile_id
    where k.key_hash = any (p_hashes)
      and p.id <> v_uid
      and not exists (
        select 1 from friendships f
        where ((f.requester_id = v_uid and f.addressee_id = p.id)
            or (f.requester_id = p.id and f.addressee_id = v_uid))
          and f.status in ('pending', 'accepted')
      )
      and not exists (
        select 1 from blocks b
        where (b.blocker_id = v_uid and b.blocked_id = p.id)
           or (b.blocker_id = p.id and b.blocked_id = v_uid)
      );
end $$;


ALTER FUNCTION "public"."match_contacts"("p_hashes" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_post_activity"() RETURNS TABLE("post_id" "uuid", "kind" "text", "actor_count" integer, "latest_at" timestamp with time zone, "actors" "jsonb", "cover_url" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with acts as (
    select pl.post_id, 'like'::text as kind, pl.user_id as actor_id, pl.created_at
    from post_likes pl join posts po on po.id = pl.post_id
    where po.author_id = auth.uid() and pl.user_id <> auth.uid()
      and pl.created_at > now() - interval '24 hours'
    union all
    select pc.post_id, 'comment'::text, pc.author_id, pc.created_at
    from post_comments pc join posts po on po.id = pc.post_id
    where po.author_id = auth.uid() and pc.author_id <> auth.uid()
      and pc.created_at > now() - interval '24 hours'
  ),
  per_actor as (
    select post_id, kind, actor_id, max(created_at) as latest
    from acts group by post_id, kind, actor_id
  )
  select pa.post_id, pa.kind, count(*)::int as actor_count, max(pa.latest) as latest_at,
    jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name,
              'username', pr.username, 'avatar', pr.avatar_url) order by pa.latest desc) as actors,
    po.cover_url
  from per_actor pa
  join profiles pr on pr.id = pa.actor_id
  join posts po on po.id = pa.post_id
  group by pa.post_id, pa.kind, po.cover_url
  order by max(pa.latest) desc;
$$;


ALTER FUNCTION "public"."my_post_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_beer_serving"("s" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $_$
  select case
    when s ~ '^[0-9]+$' and s::int between 55 and 59 then 'pint'
    else s
  end;
$_$;


ALTER FUNCTION "public"."normalize_beer_serving"("s" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."normalize_beer_serving"("s" "text") IS 'Maps a reported serving onto one the app can filter. Currently only the imperial-pint band (55-59 cl) -> ''pint''.';



CREATE OR REPLACE FUNCTION "public"."on_business_offer_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text;
begin
  if NEW.business_id is null or not NEW.is_active or not NEW.approved then return NEW; end if;
  select name into v_name from businesses where id = NEW.business_id;
  perform private.notify_business_followers(
    NEW.business_id, v_name || ': ' || NEW.title,
    coalesce(nullif(left(NEW.description, 90), ''), 'Tap for the details.'),
    jsonb_build_object('type', 'deal', 'venue_id', NEW.venue_id, 'offer_id', NEW.id, 'business_id', NEW.business_id));
  return NEW;
end $$;


ALTER FUNCTION "public"."on_business_offer_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_business_post_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text; v_body text;
begin
  select name into v_name from businesses where id = NEW.business_id;
  v_body := coalesce(nullif(left(trim(NEW.caption), 90), ''), 'Something new from ' || v_name || '.');
  perform private.notify_business_followers(
    NEW.business_id, v_name || ' posted', v_body,
    jsonb_build_object('type', 'business_post', 'business_id', NEW.business_id, 'post_id', NEW.id));
  return NEW;
end $$;


ALTER FUNCTION "public"."on_business_post_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_comment_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_author uuid; v_name text;
begin
  select author_id into v_author from posts where id = NEW.post_id;
  if v_author is null or v_author = NEW.author_id then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.author_id;
  perform private.notify_push(
    v_author, 'New comment', coalesce(v_name,'Someone') || ' commented on your night',
    jsonb_build_object('type','comment','post_id', NEW.post_id));
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_comment_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_dm_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_name text;
begin
  select p.name into v_name from profiles p where p.id = NEW.sender_id;
  perform private.notify_push(
    NEW.recipient_id,
    coalesce(v_name, 'A friend'),
    case NEW.kind
      when 'story_like'  then 'liked your story ❤️'
      when 'story_reply' then 'replied to your story: ' || left(coalesce(NEW.body, ''), 80)
      else left(coalesce(NEW.body, ''), 120)
    end,
    jsonb_build_object('type', 'dm', 'sender_id', NEW.sender_id)
  );
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_dm_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_event_invite_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_host text;
  v_title text;
begin
  if NEW.status <> 'pending' or NEW.invited_by is null then
    return NEW;
  end if;
  select p.name into v_host from profiles p where p.id = NEW.invited_by;
  select e.title into v_title from events e where e.id = NEW.event_id;
  perform private.notify_push(
    NEW.profile_id,
    '🎉 ' || coalesce(v_host, 'A friend') || ' invited you',
    coalesce(v_title, 'A new event') || ' — open PLAN to RSVP.',
    jsonb_build_object('type', 'event_invite', 'event_id', NEW.event_id)
  );
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_event_invite_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_event_rsvp_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  v_name text;
  v_title text;
  v_host uuid;
begin
  if NEW.status = OLD.status or NEW.status = 'pending' then
    return NEW;
  end if;
  select e.host_id, e.title into v_host, v_title from events e where e.id = NEW.event_id;
  if v_host is null or v_host = NEW.profile_id then
    return NEW;
  end if;
  select p.name into v_name from profiles p where p.id = NEW.profile_id;
  perform private.notify_push(
    v_host,
    coalesce(v_name, 'Someone') || case when NEW.status = 'going'
      then ' is going 🎉' else ' can''t make it' end,
    coalesce(v_title, 'Your event'),
    jsonb_build_object('type', 'event_rsvp', 'event_id', NEW.event_id)
  );
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_event_rsvp_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_friend_request_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text;
begin
  if NEW.status <> 'pending' then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.requester_id;
  perform private.notify_push(
    NEW.addressee_id, 'Friend request',
    coalesce(v_name,'Someone') || ' wants to be friends',
    jsonb_build_object('type','friend_request'));
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_friend_request_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_invite_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text;
begin
  if NEW.recipient_id is null then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.sender_id;
  perform private.notify_push(
    NEW.recipient_id, 'Sesh invite',
    coalesce(v_name,'Someone') || ' invited you to a sesh',
    jsonb_build_object('type','invite','session_id', NEW.session_id));
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_invite_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_like_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_author uuid; v_name text;
begin
  select author_id into v_author from posts where id = NEW.post_id;
  if v_author is null or v_author = NEW.user_id then return NEW; end if;
  select coalesce(nullif(name, ''), nullif(username, ''), 'Someone')
    into v_name from profiles where id = NEW.user_id;
  perform private.notify_push(
    v_author, 'New like', coalesce(v_name,'Someone') || ' liked your night',
    jsonb_build_object('type','like','post_id', NEW.post_id));
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_like_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_live_presence_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text; v_biz uuid; v_friend uuid; fr record; v_body text;
begin
  select coalesce(nullif(name, ''), nullif(username, ''), 'A friend'), business_id
    into v_name, v_biz from profiles where id = NEW.user_id;
  if v_biz is not null then return NEW; end if;
  v_body := case when coalesce(NEW.venue_name, '') <> ''
                 then 'At ' || NEW.venue_name || '. Tap to see the night.'
                 else 'Tap to see where the night''s at.' end;
  for fr in
    select * from friendships f
     where f.status = 'accepted'
       and (f.requester_id = NEW.user_id or f.addressee_id = NEW.user_id)
  loop
    v_friend := case when fr.requester_id = NEW.user_id then fr.addressee_id else fr.requester_id end;
    perform private.notify_push(v_friend, v_name || ' is live', v_body,
      jsonb_build_object('type', 'live', 'user_id', NEW.user_id));
  end loop;
  return NEW;
end $$;


ALTER FUNCTION "public"."on_live_presence_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_post_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text; v_friend uuid; fr record;
begin
  select coalesce(nullif(name, ''), nullif(username, ''), 'A friend')
    into v_name from profiles where id = NEW.author_id;
  for fr in
    select * from friendships f
    where f.status = 'accepted'
      and (f.requester_id = NEW.author_id or f.addressee_id = NEW.author_id)
  loop
    v_friend := case when fr.requester_id = NEW.author_id
                     then fr.addressee_id else fr.requester_id end;
    perform private.notify_push(
      v_friend,
      v_name || ' posted their night',
      'A fresh recap just landed on the Nightline.',
      jsonb_build_object('type', 'post', 'post_id', NEW.id)
    );
  end loop;
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_post_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_story_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_name text; v_friend uuid; fr record;
begin
  select coalesce(nullif(name, ''), nullif(username, ''), 'A friend')
    into v_name from profiles where id = NEW.profile_id;
  for fr in
    select * from friendships f
    where f.status = 'accepted'
      and (f.requester_id = NEW.profile_id or f.addressee_id = NEW.profile_id)
  loop
    v_friend := case when fr.requester_id = NEW.profile_id
                     then fr.addressee_id else fr.requester_id end;
    perform private.notify_push(
      v_friend,
      v_name || ' posted a story',
      'Catch it in TONIGHT before it''s gone.',
      jsonb_build_object('type', 'story', 'author_id', NEW.profile_id)
    );
  end loop;
  return NEW;
end; $$;


ALTER FUNCTION "public"."on_story_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_beer_prices"("p_limit" integer DEFAULT 1000000, "p_offset" integer DEFAULT 0) RETURNS TABLE("venue_id" "uuid", "venue_name" "text", "lat" double precision, "lon" double precision, "serving" "text", "currency" "text", "price" numeric, "report_count" bigint, "outdoor" boolean, "last_reported" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select v.id, v.name, v.lat, v.lon, b.serving, b.currency, b.price, b.report_count,
           v.outdoor_seating,
           (select max(bp.created_at) from beer_prices bp where bp.venue_id = v.id) as last_reported
    from venue_beer_prices() b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where coalesce(c.reason, 'unique') <> 'duplicate'
    order by v.id, b.serving
    limit greatest(0, p_limit)
    offset greatest(0, p_offset);
end $$;


ALTER FUNCTION "public"."public_beer_prices"("p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_deals"() RETURNS TABLE("venue_id" "uuid", "venue_name" "text", "lat" double precision, "lon" double precision, "title" "text", "description" "text", "kind" "text", "placement" "text", "image_url" "text", "active_days" integer[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select o.venue_id, v.name, v.lat, v.lon,
           o.title, o.description, o.kind, o.placement, o.image_url, o.active_days
    from venue_offers o
    join venues v on v.id = o.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where o.is_active and o.approved
      and coalesce(c.reason, 'unique') <> 'duplicate'
      and (o.starts_at is null or o.starts_at <= now())
      and (o.ends_at   is null or o.ends_at   >  now());
end $$;


ALTER FUNCTION "public"."public_deals"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_happy_hour_prices"() RETURNS TABLE("venue_id" "uuid", "venue_name" "text", "city" "text", "lat" double precision, "lon" double precision, "serving" "text", "currency" "text", "price" numeric, "beer" "text", "last_reported" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not rate_limit_hit('web_read_ip', request_ip(), 600, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select
      v.id, v.name, v.city, v.lat, v.lon,
      b.serving, b.currency, b.price_sek,
      nullif(
        case
          when split_part(b.note, ' · ', 2) ~* '(source_id|city=|updated=)' then ''
          else btrim(split_part(b.note, ' · ', 2))
        end, '') as beer,
      b.created_at as last_reported
    from beer_prices b
    join venues v on v.id = b.venue_id
    left join venue_canonical c on c.venue_id = v.id
    where b.note ~* '^\s*happy ?hour'
      and coalesce(c.reason, 'unique') <> 'duplicate'
      and v.city is not null
      and b.price_sek is not null
    order by v.city, b.price_sek;
end $$;


ALTER FUNCTION "public"."public_happy_hour_prices"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_rate_limits"() RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  delete from api_rate_limits where window_start < now() - interval '2 days';
$$;


ALTER FUNCTION "public"."purge_rate_limits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rate_limit_ceiling"("p_bucket" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case p_bucket
    when 'sun_horizon_user' then 60
    when 'sun_horizon_ip' then 120
    when 'sun_horizon_global' then 4000
    when 'sun_backfill' then 30
    when 'sun_horizon_venues_hour' then 400
    when 'sun_horizon_venues_day' then 1500
    when 'venue_import' then 6
    when 'web_read_ip' then 600
    when 'web_submit_ip' then 8
    when 'web_submit_ip_burst' then 3
    else 1000
  end;
$$;


ALTER FUNCTION "public"."rate_limit_ceiling"("p_bucket" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rate_limit_hit"("p_bucket" "text", "p_key" "text", "p_limit" integer, "p_window" interval DEFAULT '01:00:00'::interval) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_start timestamptz;
  v_count integer;
  v_limit integer;
begin
  if p_key is null or p_key = '' then
    p_key := 'unknown';
  end if;

  v_limit := least(greatest(p_limit, 1), public.rate_limit_ceiling(p_bucket));

  v_start := to_timestamp(
    floor(extract(epoch from now()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );

  insert into api_rate_limits (bucket, key, window_start, count)
  values (p_bucket, p_key, v_start, 1)
  on conflict (bucket, key, window_start)
    do update set count = api_rate_limits.count + 1
  returning count into v_count;

  return v_count <= v_limit;
end;
$$;


ALTER FUNCTION "public"."rate_limit_hit"("p_bucket" "text", "p_key" "text", "p_limit" integer, "p_window" interval) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rate_limit_take"("p_bucket" "text", "p_key" "text", "p_n" integer, "p_limit" integer, "p_window" interval DEFAULT '01:00:00'::interval) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_start timestamptz;
  v_count integer;
  v_limit integer;
  v_grant integer;
begin
  if p_key is null or p_key = '' then
    p_key := 'unknown';
  end if;
  if p_n is null or p_n <= 0 then
    return 0;
  end if;

  v_limit := least(greatest(p_limit, 1), public.rate_limit_ceiling(p_bucket));

  v_start := to_timestamp(
    floor(extract(epoch from now()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );

  insert into api_rate_limits (bucket, key, window_start, count)
  values (p_bucket, p_key, v_start, 0)
  on conflict (bucket, key, window_start) do nothing;

  select count into v_count
    from api_rate_limits
   where bucket = p_bucket and key = p_key and window_start = v_start
     for update;

  v_grant := greatest(0, least(p_n, v_limit - v_count));
  if v_grant > 0 then
    update api_rate_limits set count = count + v_grant
     where bucket = p_bucket and key = p_key and window_start = v_start;
  end if;
  return v_grant;
end;
$$;


ALTER FUNCTION "public"."rate_limit_take"("p_bucket" "text", "p_key" "text", "p_n" integer, "p_limit" integer, "p_window" interval) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rate_limit_take"("p_bucket" "text", "p_key" "text", "p_n" integer, "p_limit" integer, "p_window" interval) IS 'Atomically take up to p_n units from a rate-limit bucket; returns the number granted (may be 0 or partial).';



CREATE OR REPLACE FUNCTION "public"."recap_display"("p_recap" "jsonb", "p_keep_bac" boolean) RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select case when p_keep_bac then p_recap
    else jsonb_set(
           jsonb_set(coalesce(p_recap, '{}'::jsonb), '{peakBAC}', '0'::jsonb),
           '{stops}',
           coalesce((
             select jsonb_agg(jsonb_set(jsonb_set(s, '{bacOnArrival}', '0'::jsonb), '{bacOnDeparture}', '0'::jsonb))
             from jsonb_array_elements(p_recap->'stops') s
           ), '[]'::jsonb))
    end
$$;


ALTER FUNCTION "public"."recap_display"("p_recap" "jsonb", "p_keep_bac" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_venue_canonical"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_dupes integer;
begin
  delete from venue_canonical;

  with norm as (
    select id, lat, lon, external_id, created_at,
           lower(btrim(name)) as nm,
           lower(btrim(regexp_replace(coalesce(address, ''), ',\s*göteborg\s*$', '', 'i'))) as addr
    from venues
  ),
  edges as (
    select a.id as a_id, b.id as b_id
    from norm a
    join norm b on a.nm = b.nm and a.id <> b.id
    where haversine_m(a.lat, a.lon, b.lat, b.lon) <= 150
       or (a.addr = b.addr and a.addr <> '')
  ),
  comp as (
    -- min() has no uuid overload; uuid::text sorts identically to uuid.
    select s.a_id as id,
           least(s.a_id::text,
                 (select min(e.b_id::text) from edges e where e.a_id = s.a_id))::uuid as g
    from (select distinct a_id from edges) s
  ),
  survivor as (
    select c.g,
           (array_agg(v.id order by (v.external_id is null), v.created_at, v.id))[1] as winner
    from comp c
    join venues v on v.id = c.id
    group by c.g
  )
  insert into venue_canonical (venue_id, canonical_id, reason)
  select v.id,
         coalesce(s.winner, v.id),
         case when s.winner is null then 'unique'
              when s.winner = v.id then 'canonical'
              else 'duplicate' end
  from venues v
  left join comp c on c.id = v.id
  left join survivor s on s.g = c.g;

  select count(*) into v_dupes from venue_canonical where reason = 'duplicate';
  return v_dupes;
end;
$_$;


ALTER FUNCTION "public"."refresh_venue_canonical"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_venue_prominence"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_shown integer;
begin
  update venues v set prominence = case
    -- We or a user actually chose this venue, or it pays us.
    when v.source in ('curated','mapkit','user')          then 100
    when v.tier is not null and v.tier <> 'none'           then 100
    -- Someone has reported a beer price here, so we have something to show.
    when exists (select 1 from beer_prices b where b.venue_id = v.id) then 100
    -- Nightlife from OSM. This is a nightlife app, so a pub outranks a lunch place.
    when v.kind in ('bar','pub','nightclub','biergarten')  then 60
    -- Restaurants: findable by search, not drawn by default.
    else 20
  end;
  select count(*) into v_shown from venues where prominence >= 60;
  return v_shown;
end $$;


ALTER FUNCTION "public"."refresh_venue_prominence"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_device_token"("p_token" "text", "p_platform" "text" DEFAULT 'ios'::"text", "p_time_zone" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_tz text := null;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_time_zone is not null then
    begin
      perform now() at time zone p_time_zone;
      v_tz := p_time_zone;
    exception when others then v_tz := null; end;
  end if;
  insert into device_tokens (user_id, token, platform, time_zone, updated_at)
  values (auth.uid(), p_token, p_platform, v_tz, now())
  on conflict (token)
  do update set user_id    = excluded.user_id,
                platform   = excluded.platform,
                time_zone  = coalesce(excluded.time_zone, device_tokens.time_zone),
                updated_at = now();
end $$;


ALTER FUNCTION "public"."register_device_token"("p_token" "text", "p_platform" "text", "p_time_zone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_friend"("p_other" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from friendships
    where (requester_id=auth.uid() and addressee_id=p_other)
       or (requester_id=p_other and addressee_id=auth.uid());
end;
$$;


ALTER FUNCTION "public"."remove_friend"("p_other" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if not rate_limit_hit('outdoor_report', v_uid::text, 30, '1 hour') then
    raise exception 'rate_limited';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;

  update venues
     set outdoor_seating            = true,
         outdoor_seating_source     = 'user',
         outdoor_seating_updated_at = now()
   where id = p_venue
     and outdoor_seating is distinct from true;
end $$;


ALTER FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not rate_limit_hit('outdoor_report_web', request_ip(), 20, '1 hour') then
    raise exception 'rate_limited';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;

  update venues
     set outdoor_seating            = true,
         outdoor_seating_source     = 'web',
         outdoor_seating_updated_at = now()
   where id = p_venue
     and outdoor_seating is distinct from true;
end $$;


ALTER FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_sun_facade"("p_venue" "uuid", "p_bearing" smallint) RETURNS smallint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."report_sun_facade"("p_venue" "uuid", "p_bearing" smallint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_ip"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    nullif(split_part(
      current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1), ''),
    current_setting('request.headers', true)::json ->> 'cf-connecting-ip',
    'unknown'
  );
$$;


ALTER FUNCTION "public"."request_ip"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_friend_request"("p_request_id" "uuid", "p_accept" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_accept then
    update friendships set status='accepted', responded_at=now()
      where id=p_request_id and addressee_id=auth.uid() and status='pending';
  else
    delete from friendships
      where id=p_request_id and addressee_id=auth.uid() and status='pending';
  end if;
end;
$$;


ALTER FUNCTION "public"."respond_friend_request"("p_request_id" "uuid", "p_accept" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_to_event"("p_event" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."respond_to_event"("p_event" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_prompt_state"() RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object('asked_at', review_asked_at, 'done_at', review_done_at)
    from profiles where id = auth.uid();
$$;


ALTER FUNCTION "public"."review_prompt_state"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_prompt_touch"("p_done" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update profiles
     set review_asked_at = now(),
         review_done_at  = case when coalesce(p_done, false) then coalesce(review_done_at, now()) else review_done_at end
   where id = auth.uid();
  return public.review_prompt_state();
end $$;


ALTER FUNCTION "public"."review_prompt_touch"("p_done" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_admin"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid() and is_owner) then
    raise exception 'only the owner can revoke admin';
  end if;
  delete from app_admins where user_id = p_user_id and is_owner = false;
end;
$$;


ALTER FUNCTION "public"."revoke_admin"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_event_live_lifecycle"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare
  ev record;
  v_session uuid;
  v_code text;
  v_event_end timestamptz;
  v_last_activity timestamptz;
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
      'üî¥ ' || ev.title || ' just went live',
      'Your group sesh is running ‚Äî open sesh and start logging.',
      jsonb_build_object('type', 'event_live', 'event_id', ev.id)
    )
    from event_members m
    where m.event_id = ev.id and m.status = 'going';
  end loop;

  -- The session's state and its last drink ride the cursor: one statement
  -- for every running event instead of two reads per event.
  for ev in
    select e.*, s.active_live as session_active,
           (select max(d.created_at) from session_drinks d where d.session_id = e.live_session_id) as last_drink
      from events e
      left join sessions s on s.id = e.live_session_id
     where e.live_session_id is not null
       and e.live_ended_at is null
     for update of e skip locked
  loop
    if ev.session_active is distinct from true then
      update events set live_ended_at = now() where id = ev.id;
      continue;
    end if;

    v_event_end := ev.starts_at
      + make_interval(days => greatest(ev.nights, 1) - 1)
      + (ev.duration_hours * interval '1 hour');

    v_last_activity := greatest(coalesce(ev.last_drink, ev.live_started_at), ev.live_started_at);

    if now() >= v_event_end and now() >= v_last_activity + interval '6 hours' then
      update sessions set active_live = false where id = ev.live_session_id;
      update events set live_ended_at = now() where id = ev.id;
    end if;
  end loop;
exception when others then
  return;
end $$;


ALTER FUNCTION "public"."run_event_live_lifecycle"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision DEFAULT NULL::double precision, "p_lon" double precision DEFAULT NULL::double precision, "p_limit" integer DEFAULT 20) RETURNS TABLE("venue_id" "uuid", "name" "text", "lat" double precision, "lon" double precision, "horizon" smallint[], "confidence" real, "kind" "text", "prominence" smallint, "time_zone" "text", "is_override" boolean, "distance_m" double precision, "outdoor_seating" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         case when p_lat is null then null
              else haversine_m(p_lat, p_lon, v.lat, v.lon) end,
         v.outdoor_seating
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where coalesce(c.reason, 'unique') <> 'duplicate'
    and btrim(coalesce(p_query, '')) <> ''
    and v.name ilike '%' || btrim(p_query) || '%'
  order by (v.name ilike btrim(p_query) || '%') desc,
           case when p_lat is null then 0
                else haversine_m(p_lat, p_lon, v.lat, v.lon) end,
           v.prominence desc
  limit greatest(1, least(p_limit, 50));
$$;


ALTER FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision, "p_lon" double precision, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_usernames"("p_query" "text") RETURNS TABLE("id" "uuid", "name" "text", "username" "text", "avatar_url" "text", "relation" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_q text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_q := lower(trim(p_query));
  if length(v_q) < 1 then return; end if;
  return query
    select p.id, p.name, p.username, p.avatar_url,
      case
        when exists (select 1 from friendships f where f.status='accepted'
              and ((f.requester_id=auth.uid() and f.addressee_id=p.id)
                or (f.requester_id=p.id and f.addressee_id=auth.uid()))) then 'friend'
        when exists (select 1 from friendships f where f.status='pending'
              and f.requester_id=auth.uid() and f.addressee_id=p.id) then 'outgoing'
        when exists (select 1 from friendships f where f.status='pending'
              and f.requester_id=p.id and f.addressee_id=auth.uid()) then 'incoming'
        else 'none'
      end as relation
    from profiles p
    where p.username is not null
      and p.id <> auth.uid()
      and lower(p.username) like v_q || '%'
    order by p.username
    limit 10;
end;
$$;


ALTER FUNCTION "public"."search_usernames"("p_query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_friend_request"("p_username" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_target uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username)) limit 1;
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_target = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'self'); end if;

  if exists (select 1 from blocks
        where (blocker_id = auth.uid() and blocked_id = v_target)
           or (blocker_id = v_target and blocked_id = auth.uid())) then
    return jsonb_build_object('ok', false, 'reason', 'blocked');
  end if;

  if exists (select 1 from friendships where status='accepted'
        and ((requester_id=auth.uid() and addressee_id=v_target)
          or (requester_id=v_target and addressee_id=auth.uid()))) then
    return jsonb_build_object('ok', false, 'reason', 'already_friends');
  end if;

  if exists (select 1 from friendships where status='pending'
        and requester_id=v_target and addressee_id=auth.uid()) then
    update friendships set status='accepted', responded_at=now()
      where requester_id=v_target and addressee_id=auth.uid();
    return jsonb_build_object('ok', true, 'status', 'accepted');
  end if;

  insert into friendships (requester_id, addressee_id, status)
    values (auth.uid(), v_target, 'pending')
    on conflict (requester_id, addressee_id) do nothing;
  return jsonb_build_object('ok', true, 'status', 'pending');
end; $$;


ALTER FUNCTION "public"."send_friend_request"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_venue_push"("p_offer_id" "uuid", "p_title" "text", "p_body" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
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


ALTER FUNCTION "public"."send_venue_push"("p_offer_id" "uuid", "p_title" "text", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_ghost_drink_add"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."session_ghost_drink_add"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_ghost_drink_remove"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."session_ghost_drink_remove"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_ghost_remove"("p_session_id" "uuid", "p_ghost_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."session_ghost_remove"("p_session_id" "uuid", "p_ghost_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."session_ghost_upsert"("p_session_id" "uuid", "p_ghost" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."session_ghost_upsert"("p_session_id" "uuid", "p_ghost" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_business_follow_notify"("p_business" "uuid", "p_on" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update business_follows set notify = coalesce(p_on, true)
   where user_id = auth.uid() and business_id = p_business;
$$;


ALTER FUNCTION "public"."set_business_follow_notify"("p_business" "uuid", "p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_deals_location"("p_lat" double precision, "p_lon" double precision) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update profiles
     set deals_lat = p_lat, deals_lon = p_lon, deals_loc_at = now()
   where id = auth.uid();
$$;


ALTER FUNCTION "public"."set_deals_location"("p_lat" double precision, "p_lon" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_deals_push_opt_in"("p_on" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update profiles set deals_push_opt_in = coalesce(p_on, false) where id = auth.uid();
$$;


ALTER FUNCTION "public"."set_deals_push_opt_in"("p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_auto_live"("p_event" "uuid", "p_on" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events set auto_live = coalesce(p_on, auto_live)
   where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."set_event_auto_live"("p_event" "uuid", "p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_byo"("p_event" "uuid", "p_items" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events
     set byo = jsonb_set(
           coalesce(byo, '{}'::jsonb),
           array[auth.uid()::text],
           coalesce(p_items, '{}'::jsonb)
         )
   where id = p_event
     and exists (
       select 1 from event_members m
       where m.event_id = p_event
         and m.profile_id = auth.uid()
         and m.status = 'going'
     );
end; $$;


ALTER FUNCTION "public"."set_event_byo"("p_event" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_cover"("p_event" "uuid", "p_url" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events set cover_url = p_url
   where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."set_event_cover"("p_event" "uuid", "p_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_ghosts"("p_event" "uuid", "p_ghosts" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events
     set ghosts = coalesce(p_ghosts, '[]'::jsonb)
   where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."set_event_ghosts"("p_event" "uuid", "p_ghosts" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_location"("p_event" "uuid", "p_kind" "text", "p_name" "text", "p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_kind is not null and p_kind not in ('venue', 'spot') then
    raise exception 'invalid location kind';
  end if;
  update events
     set location_kind = p_kind,
         location_name = case when p_kind is null then null else p_name end,
         location      = case when p_kind is null then null else p_payload end
   where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."set_event_location"("p_event" "uuid", "p_kind" "text", "p_name" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_modes"("p_event" "uuid", "p_plan_mode" "text" DEFAULT NULL::"text", "p_edit_mode" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_plan_mode is not null and p_plan_mode not in ('calc', 'byob') then
    raise exception 'invalid plan_mode';
  end if;
  if p_edit_mode is not null and p_edit_mode not in ('host', 'everyone') then
    raise exception 'invalid edit_mode';
  end if;
  update events
     set plan_mode = coalesce(p_plan_mode, plan_mode),
         edit_mode = coalesce(p_edit_mode, edit_mode)
   where id = p_event and host_id = auth.uid();
end; $$;


ALTER FUNCTION "public"."set_event_modes"("p_event" "uuid", "p_plan_mode" "text", "p_edit_mode" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events
     set supplies = coalesce(p_supplies, '{}'::jsonb)
   where id = p_event and private.can_edit_event(p_event, auth.uid());
end; $$;


ALTER FUNCTION "public"."set_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_like"("p_post_id" "uuid", "p_like" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not can_see_post(p_post_id) then raise exception 'not allowed'; end if;
  if p_like then
    insert into post_likes(post_id, user_id) values (p_post_id, auth.uid()) on conflict do nothing;
  else
    delete from post_likes where post_id=p_post_id and user_id=auth.uid();
  end if;
end; $$;


ALTER FUNCTION "public"."set_like"("p_post_id" "uuid", "p_like" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare v_uid uuid := auth.uid(); v_n integer; v_kinds text[];
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_keys is null or jsonb_typeof(p_keys) <> 'array' then
    raise exception 'bad_request';
  end if;
  if jsonb_array_length(p_keys) > 12 then raise exception 'too_many'; end if;

  select coalesce(array_agg(distinct e->>'kind'), '{}')
    into v_kinds
  from jsonb_array_elements(p_keys) e
  where e->>'kind' in ('phone', 'email');

  if array_length(v_kinds, 1) is null then return 0; end if;

  delete from contact_keys
   where profile_id = v_uid and kind = any (v_kinds);

  insert into contact_keys (profile_id, key_hash, kind)
  select v_uid, e->>'hash', e->>'kind'
  from jsonb_array_elements(p_keys) e
  where e->>'hash' ~ '^[0-9a-f]{64}$'
    and e->>'kind' = any (v_kinds)
  on conflict (profile_id, key_hash) do nothing;

  select count(*) into v_n from contact_keys where profile_id = v_uid;
  return v_n;
end $_$;


ALTER FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_session_ghosts"("p_session_id" "uuid", "p_ghosts" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_session_member(p_session_id) then
    raise exception 'not a session member';
  end if;
  update sessions
     set ghosts = coalesce(p_ghosts, '[]'::jsonb)
   where id = p_session_id;
end;
$$;


ALTER FUNCTION "public"."set_session_ghosts"("p_session_id" "uuid", "p_ghosts" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_session_live_loose_spot"("p_session_id" "uuid", "p_spot" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_session_member(p_session_id) then
    raise exception 'not a session member';
  end if;
  update sessions
     set live_loose_spot = p_spot
   where id = p_session_id;
end;
$$;


ALTER FUNCTION "public"."set_session_live_loose_spot"("p_session_id" "uuid", "p_spot" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_session_live_venue"("p_session_id" "uuid", "p_venue" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not is_session_member(p_session_id) then
    raise exception 'not a session member';
  end if;
  update sessions
     set live_venue = p_venue
   where id = p_session_id;
end;
$$;


ALTER FUNCTION "public"."set_session_live_venue"("p_session_id" "uuid", "p_venue" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_sponsored_cards_opt_out"("p_off" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update profiles set sponsored_cards_opt_out = coalesce(p_off, false) where id = auth.uid();
$$;


ALTER FUNCTION "public"."set_sponsored_cards_opt_out"("p_off" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_username"("p_username" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare v_clean text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  v_clean := lower(trim(p_username));
  if v_clean !~ '^[a-z0-9_]{3,20}$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  if exists (select 1 from profiles where lower(username) = v_clean and id <> auth.uid()) then
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end if;
  update profiles set username = v_clean where id = auth.uid();
  return jsonb_build_object('ok', true, 'username', v_clean);
end;
$_$;


ALTER FUNCTION "public"."set_username"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_venue_time_zone"("p_venue_id" "uuid", "p_zone" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_zone is null or btrim(p_zone) = '' or length(p_zone) > 64 then return; end if;
  update venues set time_zone = p_zone
  where id = p_venue_id and time_zone is null;
end $$;


ALTER FUNCTION "public"."set_venue_time_zone"("p_venue_id" "uuid", "p_zone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_weekend_push_opt_in"("p_on" boolean) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update profiles set weekend_push_opt_in = coalesce(p_on, true) where id = auth.uid();
$$;


ALTER FUNCTION "public"."set_weekend_push_opt_in"("p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."speakeasy_act"("p_match" "uuid", "p_action" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare uid uuid := auth.uid(); m public.speakeasy_matches%rowtype;
begin
  if uid is null then raise exception 'sign in'; end if;
  perform private.speakeasy_apply(p_match, uid, p_action);
  select * into m from public.speakeasy_matches where id = p_match;
  return private.speakeasy_view_for(m, uid);
end $$;


ALTER FUNCTION "public"."speakeasy_act"("p_match" "uuid", "p_action" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."speakeasy_current"("p_session" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare uid uuid := auth.uid(); m public.speakeasy_matches%rowtype;
begin
  if uid is null or not public.is_session_member(p_session) then return null; end if;
  select * into m from public.speakeasy_matches
   where session_id = p_session and created_at > now() - interval '12 hours'
   order by created_at desc limit 1;
  if not found then return null; end if;
  return private.speakeasy_view_for(m, uid);
end $$;


ALTER FUNCTION "public"."speakeasy_current"("p_session" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."speakeasy_start"("p_session" "uuid", "p_players" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare uid uuid := auth.uid(); mid uuid; m public.speakeasy_matches%rowtype;
begin
  if uid is null or not public.is_session_member(p_session) then raise exception 'not in this sesh'; end if;
  if exists (select 1 from unnest(p_players) x where not exists (
        select 1 from public.session_members sm where sm.session_id = p_session and sm.profile_id = x)) then
    raise exception 'everyone must be in the sesh';
  end if;
  mid := private.speakeasy_create(p_session, uid, p_players);
  select * into m from public.speakeasy_matches where id = mid;
  return private.speakeasy_view_for(m, uid);
end $$;


ALTER FUNCTION "public"."speakeasy_start"("p_session" "uuid", "p_players" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sponsored_card_tapped"("p_card" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update business_card_deliveries set tapped = true where card_id = p_card and user_id = auth.uid();
$$;


ALTER FUNCTION "public"."sponsored_card_tapped"("p_card" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_beer_price"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_price" numeric DEFAULT NULL::numeric, "p_note" "text" DEFAULT NULL::"text", "p_serving" "text" DEFAULT '40'::"text", "p_currency" "text" DEFAULT 'SEK'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $_$
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
end $_$;


ALTER FUNCTION "public"."submit_beer_price"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_note" "text", "p_serving" "text", "p_currency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_beer_price_web"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_price" numeric DEFAULT NULL::numeric, "p_serving" "text" DEFAULT '40'::"text", "p_currency" "text" DEFAULT 'SEK'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $_$
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
end $_$;


ALTER FUNCTION "public"."submit_beer_price_web"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_serving" "text", "p_currency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_beverage_barcode"("p_barcode" "text", "p_name" "text", "p_category" "text", "p_volume_ml" double precision, "p_abv" double precision) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_beverage_barcode"("p_barcode" "text", "p_name" "text", "p_category" "text", "p_volume_ml" double precision, "p_abv" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sun_venue"("p_venue_id" "uuid") RETURNS TABLE("venue_id" "uuid", "name" "text", "lat" double precision, "lon" double precision, "horizon" smallint[], "confidence" real, "kind" "text", "prominence" smallint, "time_zone" "text", "is_override" boolean, "outdoor_seating" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         v.outdoor_seating
  from venues v
  join venue_sun s on s.venue_id = v.id
  where v.id = p_venue_id;
$$;


ALTER FUNCTION "public"."sun_venue"("p_venue_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sun_venue_budget_take"("p_n" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  h_start timestamptz;
  d_start timestamptz;
  h_count integer;
  d_count integer;
  h_limit integer := public.rate_limit_ceiling('sun_horizon_venues_hour');
  d_limit integer := public.rate_limit_ceiling('sun_horizon_venues_day');
  v_grant integer;
begin
  if p_n is null or p_n <= 0 then
    return 0;
  end if;

  h_start := to_timestamp(floor(extract(epoch from now()) / 3600) * 3600);
  d_start := to_timestamp(floor(extract(epoch from now()) / 86400) * 86400);

  insert into api_rate_limits (bucket, key, window_start, count)
  values ('sun_horizon_venues_hour', 'all', h_start, 0),
         ('sun_horizon_venues_day',  'all', d_start, 0)
  on conflict (bucket, key, window_start) do nothing;

  select count into h_count from api_rate_limits
   where bucket = 'sun_horizon_venues_hour' and key = 'all' and window_start = h_start
     for update;
  select count into d_count from api_rate_limits
   where bucket = 'sun_horizon_venues_day' and key = 'all' and window_start = d_start
     for update;

  v_grant := greatest(0, least(p_n, h_limit - h_count, d_limit - d_count));
  if v_grant > 0 then
    update api_rate_limits set count = count + v_grant
     where bucket = 'sun_horizon_venues_hour' and key = 'all' and window_start = h_start;
    update api_rate_limits set count = count + v_grant
     where bucket = 'sun_horizon_venues_day' and key = 'all' and window_start = d_start;
  end if;
  return v_grant;
end;
$$;


ALTER FUNCTION "public"."sun_venue_budget_take"("p_n" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sun_venue_budget_take"("p_n" integer) IS 'Atomically reserve up to p_n venue-units against BOTH the hourly and daily sun budgets; returns the number granted. A refused call charges nothing.';



CREATE OR REPLACE FUNCTION "public"."sync_venue_tier"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."sync_venue_tier"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unblock_user"("p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from blocks where blocker_id = auth.uid() and blocked_id = p_user;
end; $$;


ALTER FUNCTION "public"."unblock_user"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_plan"("p_event" "uuid", "p_target_bac" numeric DEFAULT NULL::numeric, "p_duration_hours" numeric DEFAULT NULL::numeric, "p_nights" integer DEFAULT NULL::integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update events
     set target_bac     = coalesce(p_target_bac, target_bac),
         duration_hours = coalesce(p_duration_hours, duration_hours),
         nights         = coalesce(p_nights, nights)
   where id = p_event and private.can_edit_event(p_event, auth.uid());
end; $$;


ALTER FUNCTION "public"."update_event_plan"("p_event" "uuid", "p_target_bac" numeric, "p_duration_hours" numeric, "p_nights" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_files"("p_uid" "uuid") RETURNS TABLE("bucket_id" "text", "name" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- A JWT-bearing caller may only list its own files; service_role (null
  -- auth.uid()) is the trusted backend path used by delete-account.
  if auth.uid() is not null and p_uid <> auth.uid() then
    raise exception 'forbidden';
  end if;
  return query
    select o.bucket_id, o.name from storage.objects o where o.owner = p_uid;
end $$;


ALTER FUNCTION "public"."user_files"("p_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_posts"("p_user" "uuid") RETURNS TABLE("id" "uuid", "author_id" "uuid", "author_name" "text", "author_username" "text", "author_avatar" "text", "recap" "jsonb", "include_bac" boolean, "caption" "text", "cover_url" "text", "started_at" timestamp with time zone, "created_at" timestamp with time zone, "like_count" integer, "liked_by_me" boolean, "comment_count" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where po.deleted_at is null
    and po.author_id = p_user
    and (
      p_user = auth.uid()
      or exists (select 1 from friendships f where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=p_user)
          or (f.requester_id=p_user and f.addressee_id=auth.uid())))
    )
  order by po.created_at desc;
$$;


ALTER FUNCTION "public"."user_posts"("p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."username_available"("p_username" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
  select case
    when lower(trim(p_username)) !~ '^[a-z0-9_]{3,20}$' then false
    else not exists (select 1 from profiles where lower(username) = lower(trim(p_username)))
  end;
$_$;


ALTER FUNCTION "public"."username_available"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_beer_prices"("p_limit" integer DEFAULT 1000000, "p_offset" integer DEFAULT 0, "p_country" "text" DEFAULT NULL::"text") RETURNS TABLE("venue_id" "uuid", "serving" "text", "currency" "text", "price" numeric, "report_count" bigint, "low" numeric, "high" numeric, "last_reported" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
#variable_conflict use_column
begin
  if not rate_limit_hit('catalog_read',
       coalesce(auth.uid()::text, request_ip(), 'anon'), 1200, '1 hour') then
    raise exception 'rate_limited';
  end if;
  return query
    select bp.venue_id, bp.serving,
           mode() within group (order by bp.currency),
           percentile_cont(0.5) within group (order by bp.price_sek)::numeric(6,2),
           count(*),
           min(bp.price_sek)::numeric(6,2),
           max(bp.price_sek)::numeric(6,2),
           max(bp.created_at)
    from beer_prices bp
    where (case when bp.source in ('app','web')
                then bp.created_at > now() - interval '90 days'
                else bp.created_at > now() - interval '4 years' end)
      and (p_country is null
           or exists (select 1 from venues v
                      where v.id = bp.venue_id and v.country = p_country))
    group by bp.venue_id, bp.serving
    order by bp.venue_id, bp.serving
    limit greatest(0, p_limit)
    offset greatest(0, p_offset);
end $$;


ALTER FUNCTION "public"."venue_beer_prices"("p_limit" integer, "p_offset" integer, "p_country" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_for_qr"("p_token" "text") RETURNS TABLE("id" "uuid", "name" "text", "address" "text", "city" "text", "lat" double precision, "lon" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.name, v.address, v.city, v.lat, v.lon
  from venues v
  where v.qr_token = upper(trim(p_token))
  limit 1;
$$;


ALTER FUNCTION "public"."venue_for_qr"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_heat"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision DEFAULT 25000) RETURNS TABLE("name" "text", "lat" double precision, "lon" double precision, "band" integer, "intensity" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with recent as (
    select s.profile_id,
           lower(trim(s.name)) as key,
           round(s.lat::numeric, 2) as gx,
           round(s.lon::numeric, 2) as gy,
           s.name, s.lat, s.lon
    from session_stops s
    where s.kind = 'bar'
      and s.profile_id is not null
      and s.lat is not null and s.lon is not null
      and s.arrived_at > now() - interval '8 hours'
      and haversine_m(p_lat, p_lon, s.lat, s.lon) <= p_radius_m
  ),
  clustered as (
    select key, gx, gy,
           count(distinct profile_id) as people,
           avg(lat) as lat, avg(lon) as lon,
           mode() within group (order by name) as name
    from recent
    group by key, gx, gy
  ),
  visible as (
    select * from clustered where people >= 3 and name is not null
  ),
  ctx as (
    select (select count(distinct profile_id) from recent)::numeric as total,
           (select max(people) from visible)::numeric               as leader
  ),
  -- one row per bar per past NIGHT (shifted 6h so a night spanning midnight
  -- counts once), excluding the live window so tonight can't skew its own
  -- baseline
  hist as (
    select lower(trim(s.name)) as key,
           round(s.lat::numeric, 2) as gx,
           round(s.lon::numeric, 2) as gy,
           date_trunc('day', s.arrived_at - interval '6 hours') as night,
           count(distinct s.profile_id) as people
    from session_stops s
    where s.kind = 'bar'
      and s.profile_id is not null
      and s.lat is not null and s.lon is not null
      and s.arrived_at <= now() - interval '8 hours'
      and s.arrived_at >  now() - interval '28 days'
      and haversine_m(p_lat, p_lon, s.lat, s.lon) <= p_radius_m
    group by 1, 2, 3, 4
  ),
  baseline as (
    select key, gx, gy,
           percentile_cont(0.5) within group (order by people) as typical,
           count(*) as nights
    from hist
    group by key, gx, gy
  )
  select v.name, v.lat, v.lon,
         greatest(
           -- learned: tonight vs this bar's own normal (needs 4+ prior nights)
           case
             when b.nights >= 4 and v.people >= 5 then
               case when v.people >= b.typical * 1.6 then 3
                    when v.people >= b.typical * 1.1 then 2
                    else 1 end
             else 1
           end,
           -- area-relative: share of everyone out around here tonight
           case
             when v.people >= 5 and (v.people / ctx.total >= 0.35 or v.people >= 25) then 3
             when v.people >= 5 and (v.people / ctx.total >= 0.15 or v.people >= 12) then 2
             else 1
           end
         ) as band,
         round(least(1.0, greatest(0.25, v.people / ctx.leader)) * 20) / 20
           as intensity
  from visible v
  left join baseline b using (key, gx, gy), ctx;
$$;


ALTER FUNCTION "public"."venue_heat"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_request_counts"("p_venues" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_object_agg(venue_id::text, n), '{}'::jsonb)
  from (select venue_id, count(*) as n from venue_requests where venue_id = any(p_venues) group by venue_id) t
$$;


ALTER FUNCTION "public"."venue_request_counts"("p_venues" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_request_set"("p_venue" "uuid", "p_on" boolean) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private'
    AS $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from venues where id = p_venue) then raise exception 'no_venue'; end if;
  if p_on then
    if exists (select 1 from businesses b where b.venue_id = p_venue and b.status = 'approved' and private.biz_tier(b.id) <> 'none') then
      raise exception 'already_on_sejdel';
    end if;
    insert into venue_requests (venue_id, user_id) values (p_venue, v_me) on conflict do nothing;
  else
    delete from venue_requests where venue_id = p_venue and user_id = v_me;
  end if;
  return (select count(*) from venue_requests where venue_id = p_venue);
end $$;


ALTER FUNCTION "public"."venue_request_set"("p_venue" "uuid", "p_on" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_requests_mine"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(jsonb_agg(venue_id), '[]'::jsonb) from venue_requests where user_id = auth.uid()
$$;


ALTER FUNCTION "public"."venue_requests_mine"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_specials_curated_only"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  parent_source text;
begin
  select source into parent_source from venues where id = new.venue_id;
  if parent_source is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  if parent_source <> 'curated' then
    raise exception 'venue_specials may only attach to curated venues (got %)', parent_source;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."venue_specials_curated_only"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) RETURNS TABLE("venue_id" "uuid", "name" "text", "lat" double precision, "lon" double precision, "horizon" smallint[], "confidence" real, "kind" "text", "prominence" smallint, "time_zone" "text", "is_override" boolean, "facade_bearing" smallint, "facade_reports" smallint, "outdoor_seating" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         s.facade_bearing, s.facade_reports,
         v.outdoor_seating
    from venues v
    join venue_sun s on s.venue_id = v.id
   where v.id = any(p_ids)
   limit 400;
$$;


ALTER FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision DEFAULT 25000, "p_limit" integer DEFAULT 80, "p_min_prominence" smallint DEFAULT 60) RETURNS TABLE("venue_id" "uuid", "name" "text", "lat" double precision, "lon" double precision, "horizon" smallint[], "confidence" real, "kind" "text", "prominence" smallint, "time_zone" "text", "is_override" boolean, "facade_bearing" smallint, "facade_reports" smallint, "outdoor_seating" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with nearby as (
    select v.id, v.name, v.lat, v.lon,
           coalesce(s.override_horizon, s.horizon) as horizon,
           s.confidence, v.kind, v.prominence, v.time_zone,
           (s.override_horizon is not null) as is_override,
           s.facade_bearing, s.facade_reports,
           v.outdoor_seating,
           exists (select 1 from beer_prices b where b.venue_id = v.id) as priced,
           haversine_m(p_lat, p_lon, v.lat, v.lon) as dist
      from venues v
      join venue_sun s on s.venue_id = v.id
      left join venue_canonical c on c.venue_id = v.id
     where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
       and coalesce(c.reason, 'unique') <> 'duplicate'
  )
  select id, name, lat, lon, horizon, confidence, kind, prominence,
         time_zone, is_override, facade_bearing, facade_reports, outdoor_seating
    from nearby
   where priced or prominence >= p_min_prominence
   order by priced desc, dist
   limit greatest(1, least(p_limit, 400));
$$;


ALTER FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer, "p_min_prominence" smallint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venues_missing_sun"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision DEFAULT 25000, "p_limit" integer DEFAULT 12) RETURNS TABLE("venue_id" "uuid", "lat" double precision, "lon" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.lat, v.lon
  from venues v
  left join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where s.venue_id is null
    and coalesce(c.reason, 'unique') <> 'duplicate'
    and haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
  order by v.prominence desc, haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit p_limit;
$$;


ALTER FUNCTION "public"."venues_missing_sun"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."venues_needing_sun"("p_limit" integer DEFAULT 100) RETURNS TABLE("id" "uuid", "lat" double precision, "lon" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select v.id, v.lat, v.lon
    from venues v
   where v.lat is not null
     and v.lon is not null
     and not exists (select 1 from venue_sun s where s.venue_id = v.id)
   order by
     (exists (select 1 from beer_prices b where b.venue_id = v.id)) desc,
     coalesce(v.prominence, 0) desc,
     v.id
   limit greatest(1, least(p_limit, 500));
$$;


ALTER FUNCTION "public"."venues_needing_sun"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."widmark_bac"("p_events" "jsonb", "p_weight_kg" double precision, "p_sex" "text", "p_at" timestamp with time zone) RETURNS double precision
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
declare
  r float8 := case when p_sex = 'male' then 0.68 else 0.55 end;
  denom float8 := coalesce(p_weight_kg, 0) * 1000 * r;
  bac float8 := 0;
  last_t timestamptz := null;
  e record;
begin
  if denom <= 0 then return 0; end if;
  for e in
    select (x->>'t')::timestamptz as t, (x->>'g')::float8 as g
    from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) x
    where (x->>'t')::timestamptz <= p_at
    order by 1
  loop
    if last_t is not null then
      bac := greatest(0, bac - 0.015 * extract(epoch from e.t - last_t) / 3600.0);
    end if;
    bac := bac + (e.g / denom) * 100;
    last_t := e.t;
  end loop;
  if last_t is not null then
    bac := greatest(0, bac - 0.015 * extract(epoch from p_at - last_t) / 3600.0);
  end if;
  return bac;
end $$;


ALTER FUNCTION "public"."widmark_bac"("p_events" "jsonb", "p_weight_kg" double precision, "p_sex" "text", "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."app_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "private"."app_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."push_config" (
    "id" integer DEFAULT 1 NOT NULL,
    "function_url" "text" NOT NULL,
    "secret" "text" NOT NULL,
    CONSTRAINT "push_config_singleton" CHECK (("id" = 1))
);


ALTER TABLE "private"."push_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."push_outbox" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone
);


ALTER TABLE "private"."push_outbox" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "private"."push_outbox_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "private"."push_outbox_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "private"."push_outbox_id_seq" OWNED BY "private"."push_outbox"."id";



CREATE TABLE IF NOT EXISTS "private"."weekend_push_log" (
    "user_id" "uuid" NOT NULL,
    "week_start" "date" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "private"."weekend_push_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."announcements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_by" "uuid",
    "recipients" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."announcements" OWNER TO "postgres";


COMMENT ON TABLE "public"."announcements" IS 'Audit trail of product-update pushes sent to the whole user base.';



CREATE TABLE IF NOT EXISTS "public"."api_rate_limits" (
    "bucket" "text" NOT NULL,
    "key" "text" NOT NULL,
    "window_start" timestamp with time zone NOT NULL,
    "count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."api_rate_limits" OWNER TO "postgres";


COMMENT ON TABLE "public"."api_rate_limits" IS 'Fixed-window API rate limit counters. Written only by rate_limit_hit().';



CREATE TABLE IF NOT EXISTS "public"."app_admins" (
    "user_id" "uuid" NOT NULL,
    "is_owner" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."app_admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "build" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_feedback_message_check" CHECK ((("length"("message") >= 1) AND ("length"("message") <= 2000)))
);


ALTER TABLE "public"."app_feedback" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."beer_prices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "price_sek" numeric(6,2) NOT NULL,
    "serving" "text" DEFAULT '40'::"text" NOT NULL,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "currency" "text" DEFAULT 'SEK'::"text" NOT NULL,
    "source" "text" DEFAULT 'app'::"text" NOT NULL,
    "serving_raw" "text",
    CONSTRAINT "beer_prices_price_sek_check" CHECK ((("price_sek" > (0)::numeric) AND ("price_sek" < (1000)::numeric))),
    CONSTRAINT "beer_prices_serving_chk" CHECK ((("serving" = ANY (ARRAY['pint'::"text", 'unknown'::"text"])) OR (("serving" ~ '^[0-9]+(?:\.[0-9]+)?$'::"text") AND ((("serving")::numeric >= (1)::numeric) AND (("serving")::numeric <= (200)::numeric)))))
);


ALTER TABLE "public"."beer_prices" OWNER TO "postgres";


COMMENT ON COLUMN "public"."beer_prices"."serving_raw" IS 'Serving exactly as reported, before normalisation (see 082). Null = never normalised.';



CREATE TABLE IF NOT EXISTS "public"."beverage_barcode_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "barcode" "text" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "volume_ml" double precision NOT NULL,
    "abv" double precision NOT NULL,
    "content_sig" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."beverage_barcode_submissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."beverage_barcodes" (
    "barcode" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" DEFAULT 'beer'::"text" NOT NULL,
    "volume_ml" double precision NOT NULL,
    "abv" double precision NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."beverage_barcodes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."blocks" (
    "blocker_id" "uuid" NOT NULL,
    "blocked_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_boosts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "product_id" "text" NOT NULL,
    "goal_views" integer NOT NULL,
    "views" integer DEFAULT 0 NOT NULL,
    "taps" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "apple_transaction_id" "text",
    "apple_original_transaction_id" "text",
    "apple_jws" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "paid_at" timestamp with time zone,
    "done_at" timestamp with time zone,
    CONSTRAINT "business_boosts_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'live'::"text", 'done'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."business_boosts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_card_deliveries" (
    "card_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "delivered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tapped" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."business_card_deliveries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "offer_id" "uuid" NOT NULL,
    "audience_cap" integer NOT NULL,
    "delivered" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "starts_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ends_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_cards_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'live'::"text", 'done'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."business_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "image_ratio" real DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."business_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_follows" (
    "user_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notify" boolean DEFAULT true NOT NULL,
    "last_notified_at" timestamp with time zone
);


ALTER TABLE "public"."business_follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_limits" (
    "key" "text" NOT NULL,
    "value" integer NOT NULL,
    "label" "text" NOT NULL
);


ALTER TABLE "public"."business_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "offer_id" "uuid",
    "card_id" "uuid",
    "push_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "paid" boolean DEFAULT false NOT NULL,
    "amount_sek" integer DEFAULT 0 NOT NULL,
    "detail" "text",
    "reject_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "product_id" "text",
    "quantity" integer DEFAULT 1 NOT NULL,
    "apple_transaction_id" "text",
    "apple_original_transaction_id" "text",
    "apple_jws" "text",
    "paid_at" timestamp with time zone,
    CONSTRAINT "business_orders_kind_check" CHECK (("kind" = ANY (ARRAY['pin'::"text", 'poster'::"text", 'billboard'::"text", 'card'::"text", 'push'::"text"]))),
    CONSTRAINT "business_orders_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."business_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_post_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."business_post_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_post_likes" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."business_post_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "image_url" "text" NOT NULL,
    "image_ratio" real DEFAULT 1 NOT NULL,
    "caption" "text",
    "event_at" timestamp with time zone,
    "offer_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "image_urls" "text"[]
);


ALTER TABLE "public"."business_posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_push_receipts" (
    "push_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."business_push_receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_pushes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "offer_id" "uuid",
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "audience_cap" integer NOT NULL,
    "send_at" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "recipient_count" integer DEFAULT 0 NOT NULL,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_pushes_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'sent'::"text", 'rejected'::"text", 'cancelled'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."business_pushes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_subscription_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "product_id" "text",
    "tier" "text",
    "expires_at" timestamp with time zone,
    "apple_original_transaction_id" "text",
    "apple_transaction_id" "text",
    "apple_jws" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."business_subscription_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."campaign_stats" (
    "campaign_id" "uuid" NOT NULL,
    "day" "date" DEFAULT ("now"())::"date" NOT NULL,
    "impressions" integer DEFAULT 0 NOT NULL,
    "taps" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."campaign_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contact_keys" (
    "profile_id" "uuid" NOT NULL,
    "key_hash" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contact_keys_kind_check" CHECK (("kind" = ANY (ARRAY['phone'::"text", 'email'::"text"])))
);


ALTER TABLE "public"."contact_keys" OWNER TO "postgres";


COMMENT ON TABLE "public"."contact_keys" IS 'Salted SHA-256 digests of a user''s own phone/email, for contact discovery (098). Never raw values; owner-readable only; matching goes through match_contacts().';



CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "platform" "text" DEFAULT 'ios'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "time_zone" "text"
);


ALTER TABLE "public"."device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dm_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "kind" "text" DEFAULT 'text'::"text" NOT NULL,
    "body" "text",
    "story_id" "uuid",
    "story_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "list_request_id" "uuid",
    CONSTRAINT "dm_messages_body_check" CHECK (("char_length"("body") <= 1000)),
    CONSTRAINT "dm_messages_check" CHECK ((("kind" = 'story_like'::"text") OR ("body" IS NOT NULL))),
    CONSTRAINT "dm_messages_kind_check" CHECK (("kind" = ANY (ARRAY['text'::"text", 'story_reply'::"text", 'story_like'::"text", 'list_request'::"text"])))
);


ALTER TABLE "public"."dm_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."dm_messages"."updated_at" IS 'Set by trigger on every update; DMService''s incremental poll cursor (096). Deletions are not tracked — DMs have no delete path.';



CREATE TABLE IF NOT EXISTS "public"."event_members" (
    "event_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "invited_by" "uuid",
    "responded_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_members_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'going'::"text", 'declined'::"text"])))
);


ALTER TABLE "public"."event_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "host_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "kind" "text" DEFAULT 'party'::"text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "duration_hours" numeric DEFAULT 6 NOT NULL,
    "nights" integer DEFAULT 1 NOT NULL,
    "target_bac" numeric DEFAULT 0.08 NOT NULL,
    "supplies" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "ghosts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plan_mode" "text" DEFAULT 'calc'::"text" NOT NULL,
    "edit_mode" "text" DEFAULT 'host'::"text" NOT NULL,
    "byo" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "cover_url" "text",
    "auto_live" boolean DEFAULT false NOT NULL,
    "live_session_id" "uuid",
    "live_started_at" timestamp with time zone,
    "live_ended_at" timestamp with time zone,
    "location_kind" "text",
    "location_name" "text",
    "location" "jsonb",
    CONSTRAINT "events_duration_hours_check" CHECK ((("duration_hours" >= (1)::numeric) AND ("duration_hours" <= (24)::numeric))),
    CONSTRAINT "events_edit_mode_check" CHECK (("edit_mode" = ANY (ARRAY['host'::"text", 'everyone'::"text"]))),
    CONSTRAINT "events_kind_check" CHECK (("kind" = ANY (ARRAY['party'::"text", 'trip'::"text", 'pregame'::"text", 'other'::"text"]))),
    CONSTRAINT "events_location_kind_check" CHECK (("location_kind" = ANY (ARRAY['venue'::"text", 'spot'::"text"]))),
    CONSTRAINT "events_nights_check" CHECK ((("nights" >= 1) AND ("nights" <= 14))),
    CONSTRAINT "events_plan_mode_check" CHECK (("plan_mode" = ANY (ARRAY['calc'::"text", 'byob'::"text"]))),
    CONSTRAINT "events_target_bac_check" CHECK ((("target_bac" >= 0.01) AND ("target_bac" <= 0.12))),
    CONSTRAINT "events_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 80)))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."friendships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "addressee_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "responded_at" timestamp with time zone,
    CONSTRAINT "friendships_check" CHECK (("requester_id" <> "addressee_id")),
    CONSTRAINT "friendships_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text"])))
);


ALTER TABLE "public"."friendships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."game_rounds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "host_id" "uuid" NOT NULL,
    "kind" "text" DEFAULT 'imposter'::"text" NOT NULL,
    "word" "text" NOT NULL,
    "imposter_id" "uuid" NOT NULL,
    "starter_id" "uuid" NOT NULL,
    "player_ids" "uuid"[] NOT NULL,
    "spicy" boolean DEFAULT false NOT NULL,
    "revealed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "imposter_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL
);


ALTER TABLE "public"."game_rounds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "join_code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "responded_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "mode" "text" DEFAULT 'plan'::"text" NOT NULL,
    CONSTRAINT "invites_mode_check" CHECK (("mode" = ANY (ARRAY['plan'::"text", 'live'::"text"]))),
    CONSTRAINT "invites_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_guest_flags" (
    "business_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "flag" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "list_guest_flags_flag_check" CHECK (("flag" = ANY (ARRAY['favorite'::"text", 'blocked'::"text"])))
);


ALTER TABLE "public"."list_guest_flags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."list_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "instagram" "text",
    "plus_count" integer DEFAULT 0 NOT NULL,
    "night" "date" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "decided_at" timestamp with time zone,
    CONSTRAINT "list_requests_full_name_check" CHECK ((("char_length"("full_name") >= 2) AND ("char_length"("full_name") <= 80))),
    CONSTRAINT "list_requests_instagram_check" CHECK ((("char_length"("instagram") >= 1) AND ("char_length"("instagram") <= 40))),
    CONSTRAINT "list_requests_plus_count_check" CHECK ((("plus_count" >= 0) AND ("plus_count" <= 50))),
    CONSTRAINT "list_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'declined'::"text"])))
);


ALTER TABLE "public"."list_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_presence" (
    "user_id" "uuid" NOT NULL,
    "started_at" timestamp with time zone,
    "venue_name" "text",
    "session_id" "uuid",
    "drinks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "venue_lat" double precision,
    "venue_lon" double precision
);


ALTER TABLE "public"."live_presence" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_stories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "caption" "text",
    "bac" double precision,
    "stamp" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."live_stories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."post_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post_likes" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."post_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "recap" "jsonb" NOT NULL,
    "include_bac" boolean DEFAULT false NOT NULL,
    "cover_url" "text",
    "started_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "caption" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "age" integer NOT NULL,
    "sex" "text" NOT NULL,
    "weight_kg" double precision NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "avatar_url" "text",
    "username" "text",
    "deals_push_opt_in" boolean DEFAULT false NOT NULL,
    "deals_lat" double precision,
    "deals_lon" double precision,
    "deals_loc_at" timestamp with time zone,
    "birthdate" "date",
    "sponsored_cards_opt_out" boolean DEFAULT false NOT NULL,
    "business_id" "uuid",
    "review_asked_at" timestamp with time zone,
    "review_done_at" timestamp with time zone,
    "weekend_push_opt_in" boolean DEFAULT true NOT NULL,
    "disclaimer_ack_at" timestamp with time zone,
    "disclaimer_ack_version" "text",
    CONSTRAINT "profiles_age_check" CHECK ((("age" >= 18) AND ("age" <= 120))),
    CONSTRAINT "profiles_sex_check" CHECK (("sex" = ANY (ARRAY['male'::"text", 'female'::"text"]))),
    CONSTRAINT "profiles_username_format" CHECK ((("username" IS NULL) OR ("username" ~ '^[a-z0-9_]{3,20}$'::"text"))),
    CONSTRAINT "profiles_weight_kg_check" CHECK (("weight_kg" > (0)::double precision))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reporter_id" "uuid" NOT NULL,
    "target_kind" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "target_user_id" "uuid",
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "action_taken" "text",
    CONSTRAINT "reports_target_kind_check" CHECK (("target_kind" = ANY (ARRAY['user'::"text", 'post'::"text", 'story'::"text"])))
);


ALTER TABLE "public"."reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_drinks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "drink_name" "text" NOT NULL,
    "volume_ml" double precision NOT NULL,
    "abv" double precision NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shared" boolean DEFAULT false NOT NULL,
    "live" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."session_drinks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_members" (
    "session_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "in_plan" boolean DEFAULT true NOT NULL,
    "in_live" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."session_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_snaps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "stop_name" "text",
    "storage_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."session_snaps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_stops" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "lat" double precision,
    "lon" double precision,
    "arrived_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "departed_at" timestamp with time zone,
    "kind" "text" DEFAULT 'bar'::"text" NOT NULL,
    "profile_id" "uuid"
);


ALTER TABLE "public"."session_stops" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "host_id" "uuid" NOT NULL,
    "join_code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "current_venue_id" "uuid",
    "active_plan" boolean DEFAULT true NOT NULL,
    "active_live" boolean DEFAULT true NOT NULL,
    "ghosts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "live_venue" "jsonb",
    "live_loose_spot" "jsonb"
);


ALTER TABLE "public"."sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."story_views" (
    "story_id" "uuid" NOT NULL,
    "viewer_id" "uuid" NOT NULL,
    "viewed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."story_views" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_canonical" (
    "venue_id" "uuid" NOT NULL,
    "canonical_id" "uuid" NOT NULL,
    "reason" "text",
    "refreshed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."venue_canonical" OWNER TO "postgres";


COMMENT ON TABLE "public"."venue_canonical" IS 'Maps each venue to the row that should represent it. venue_id = canonical_id means it IS canonical. Rebuild with refresh_venue_canonical().';



CREATE TABLE IF NOT EXISTS "public"."venue_offers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "kind" "text" DEFAULT 'price'::"text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "fine_print" "text",
    "redeem" "text" DEFAULT 'show'::"text" NOT NULL,
    "code" "text",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "active_days" integer[],
    "start_minute" integer,
    "end_minute" integer,
    "is_active" boolean DEFAULT true NOT NULL,
    "approved" boolean DEFAULT false NOT NULL,
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "placement" "text" DEFAULT 'pin'::"text" NOT NULL,
    "billboard_image_url" "text",
    "interstitial" boolean DEFAULT false NOT NULL,
    "show_on_valid_only" boolean DEFAULT false NOT NULL,
    "business_id" "uuid",
    CONSTRAINT "venue_offers_placement_check" CHECK (("placement" = ANY (ARRAY['pin'::"text", 'poster'::"text", 'billboard'::"text"])))
);


ALTER TABLE "public"."venue_offers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_push_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "offer_id" "uuid",
    "sent_by" "uuid",
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "recipient_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."venue_push_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_requests" (
    "venue_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."venue_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_specials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venue_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "detail" "text",
    "volume_ml" double precision NOT NULL,
    "abv" double precision NOT NULL,
    "category" "text" DEFAULT 'cocktail'::"text" NOT NULL,
    "emoji" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."venue_specials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venue_sun" (
    "venue_id" "uuid" NOT NULL,
    "horizon" smallint[] NOT NULL,
    "confidence" real DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'osm'::"text" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "override_horizon" smallint[],
    "override_note" "text",
    "override_at" timestamp with time zone,
    "facade_bearing" smallint,
    "facade_reports" smallint DEFAULT 0 NOT NULL,
    CONSTRAINT "venue_sun_horizon_len" CHECK (("array_length"("horizon", 1) = 72)),
    CONSTRAINT "venue_sun_override_bins" CHECK ((("override_horizon" IS NULL) OR ("array_length"("override_horizon", 1) = 72)))
);


ALTER TABLE "public"."venue_sun" OWNER TO "postgres";


COMMENT ON COLUMN "public"."venue_sun"."override_horizon" IS 'Hand-set horizon that wins over the computed one. Survives recomputes. Null = trust the model.';



COMMENT ON COLUMN "public"."venue_sun"."facade_bearing" IS 'Compass bearing the seating faces, agreed from user reports (see 090). Fed to the sun-horizon function so it casts from THAT side instead of guessing the sunniest one.';



CREATE TABLE IF NOT EXISTS "public"."venue_sun_facade_reports" (
    "venue_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "bearing" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "venue_sun_facade_reports_bearing_check" CHECK ((("bearing" >= 0) AND ("bearing" < 360)))
);


ALTER TABLE "public"."venue_sun_facade_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."venues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "city" "text",
    "lat" double precision NOT NULL,
    "lon" double precision NOT NULL,
    "is_featured" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'curated'::"text" NOT NULL,
    "external_id" "text",
    "tier" "text" DEFAULT 'none'::"text" NOT NULL,
    "qr_token" "text",
    "kind" "text",
    "prominence" smallint DEFAULT 20 NOT NULL,
    "time_zone" "text",
    "opening_hours" "text",
    "opening_hours_source" "text",
    "mapkit_id" "text",
    "mapkit_checked_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "outdoor_seating" boolean DEFAULT false NOT NULL,
    "outdoor_seating_source" "text",
    "outdoor_seating_updated_at" timestamp with time zone,
    "country" "text",
    CONSTRAINT "venues_source_check" CHECK (("source" = ANY (ARRAY['curated'::"text", 'mapkit'::"text", 'user'::"text", 'osm'::"text"]))),
    CONSTRAINT "venues_tier_check" CHECK (("tier" = ANY (ARRAY['none'::"text", 'pin'::"text", 'poster'::"text", 'billboard'::"text"])))
);


ALTER TABLE "public"."venues" OWNER TO "postgres";


COMMENT ON COLUMN "public"."venues"."kind" IS 'bar|pub|nightclub|biergarten|restaurant|null — OSM amenity for imported rows.';



COMMENT ON COLUMN "public"."venues"."prominence" IS 'Higher = shown on the map sooner. See 076 migration for the scale.';



COMMENT ON COLUMN "public"."venues"."time_zone" IS 'IANA zone (e.g. Asia/Singapore). Used to resolve the venue local day and to format sun times. Null = client falls back to a longitude estimate.';



COMMENT ON COLUMN "public"."venues"."opening_hours" IS 'Raw OSM opening_hours syntax, e.g. "Mo-Th 16:00-01:00; Fr,Sa 15:00-03:00". Parsed on device.';



COMMENT ON COLUMN "public"."venues"."opening_hours_source" IS 'Where the hours came from: osm | user | venue. Null when unknown.';



COMMENT ON COLUMN "public"."venues"."mapkit_id" IS 'Apple Maps place id (same space as MKMapItem.identifier). Null = not resolved, see mapkit_checked_at for whether we tried.';



COMMENT ON COLUMN "public"."venues"."mapkit_checked_at" IS 'When we last asked Apple Maps about this venue, successful or not — stops us re-querying misses forever.';



COMMENT ON COLUMN "public"."venues"."updated_at" IS 'Set by trigger on every update; the app''s incremental-sync cursor (see 088). Deletions are not tracked — the client full-resyncs daily.';



COMMENT ON COLUMN "public"."venues"."outdoor_seating" IS 'Whether the venue has outdoor seating.';



COMMENT ON COLUMN "public"."venues"."outdoor_seating_source" IS 'Source that reported the outdoor seating status.';



COMMENT ON COLUMN "public"."venues"."outdoor_seating_updated_at" IS 'When the outdoor seating status was last refreshed.';



ALTER TABLE ONLY "private"."push_outbox" ALTER COLUMN "id" SET DEFAULT "nextval"('"private"."push_outbox_id_seq"'::"regclass");



ALTER TABLE ONLY "private"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "private"."push_config"
    ADD CONSTRAINT "push_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "private"."push_outbox"
    ADD CONSTRAINT "push_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "private"."weekend_push_log"
    ADD CONSTRAINT "weekend_push_log_pkey" PRIMARY KEY ("user_id", "week_start");



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."api_rate_limits"
    ADD CONSTRAINT "api_rate_limits_pkey" PRIMARY KEY ("bucket", "key", "window_start");



ALTER TABLE ONLY "public"."app_admins"
    ADD CONSTRAINT "app_admins_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."app_feedback"
    ADD CONSTRAINT "app_feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."beer_prices"
    ADD CONSTRAINT "beer_prices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."beverage_barcode_submissions"
    ADD CONSTRAINT "beverage_barcode_submissions_barcode_submitted_by_key" UNIQUE ("barcode", "submitted_by");



ALTER TABLE ONLY "public"."beverage_barcode_submissions"
    ADD CONSTRAINT "beverage_barcode_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."beverage_barcodes"
    ADD CONSTRAINT "beverage_barcodes_pkey" PRIMARY KEY ("barcode");



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_pkey" PRIMARY KEY ("blocker_id", "blocked_id");



ALTER TABLE ONLY "public"."business_boosts"
    ADD CONSTRAINT "business_boosts_apple_transaction_id_key" UNIQUE ("apple_transaction_id");



ALTER TABLE ONLY "public"."business_boosts"
    ADD CONSTRAINT "business_boosts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_card_deliveries"
    ADD CONSTRAINT "business_card_deliveries_pkey" PRIMARY KEY ("card_id", "user_id");



ALTER TABLE ONLY "public"."business_cards"
    ADD CONSTRAINT "business_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_events"
    ADD CONSTRAINT "business_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_follows"
    ADD CONSTRAINT "business_follows_pkey" PRIMARY KEY ("user_id", "business_id");



ALTER TABLE ONLY "public"."business_limits"
    ADD CONSTRAINT "business_limits_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_post_comments"
    ADD CONSTRAINT "business_post_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_post_likes"
    ADD CONSTRAINT "business_post_likes_pkey" PRIMARY KEY ("post_id", "user_id");



ALTER TABLE ONLY "public"."business_posts"
    ADD CONSTRAINT "business_posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_products"
    ADD CONSTRAINT "business_products_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."business_push_receipts"
    ADD CONSTRAINT "business_push_receipts_pkey" PRIMARY KEY ("push_id", "user_id");



ALTER TABLE ONLY "public"."business_pushes"
    ADD CONSTRAINT "business_pushes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_subscription_log"
    ADD CONSTRAINT "business_subscription_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."campaign_stats"
    ADD CONSTRAINT "campaign_stats_pkey" PRIMARY KEY ("campaign_id", "day");



ALTER TABLE ONLY "public"."contact_keys"
    ADD CONSTRAINT "contact_keys_pkey" PRIMARY KEY ("profile_id", "key_hash");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_members"
    ADD CONSTRAINT "event_members_pkey" PRIMARY KEY ("event_id", "profile_id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_requester_id_addressee_id_key" UNIQUE ("requester_id", "addressee_id");



ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_session_id_recipient_id_key" UNIQUE ("session_id", "recipient_id");



ALTER TABLE ONLY "public"."list_guest_flags"
    ADD CONSTRAINT "list_guest_flags_pkey" PRIMARY KEY ("business_id", "user_id");



ALTER TABLE ONLY "public"."list_requests"
    ADD CONSTRAINT "list_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."live_presence"
    ADD CONSTRAINT "live_presence_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."live_stories"
    ADD CONSTRAINT "live_stories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post_comments"
    ADD CONSTRAINT "post_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post_likes"
    ADD CONSTRAINT "post_likes_pkey" PRIMARY KEY ("post_id", "user_id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."session_drinks"
    ADD CONSTRAINT "session_drinks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."session_members"
    ADD CONSTRAINT "session_members_pkey" PRIMARY KEY ("session_id", "profile_id");



ALTER TABLE ONLY "public"."session_snaps"
    ADD CONSTRAINT "session_snaps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."session_stops"
    ADD CONSTRAINT "session_stops_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_join_code_key" UNIQUE ("join_code");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."speakeasy_matches"
    ADD CONSTRAINT "speakeasy_matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."story_views"
    ADD CONSTRAINT "story_views_pkey" PRIMARY KEY ("story_id", "viewer_id");



ALTER TABLE ONLY "public"."venue_campaigns"
    ADD CONSTRAINT "venue_campaigns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venue_canonical"
    ADD CONSTRAINT "venue_canonical_pkey" PRIMARY KEY ("venue_id");



ALTER TABLE ONLY "public"."venue_offers"
    ADD CONSTRAINT "venue_offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venue_push_log"
    ADD CONSTRAINT "venue_push_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venue_requests"
    ADD CONSTRAINT "venue_requests_pkey" PRIMARY KEY ("venue_id", "user_id");



ALTER TABLE ONLY "public"."venue_specials"
    ADD CONSTRAINT "venue_specials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venue_sun_facade_reports"
    ADD CONSTRAINT "venue_sun_facade_reports_pkey" PRIMARY KEY ("venue_id", "profile_id");



ALTER TABLE ONLY "public"."venue_sun"
    ADD CONSTRAINT "venue_sun_pkey" PRIMARY KEY ("venue_id");



ALTER TABLE ONLY "public"."venues"
    ADD CONSTRAINT "venues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."venues"
    ADD CONSTRAINT "venues_qr_token_key" UNIQUE ("qr_token");



CREATE INDEX "push_outbox_pending_idx" ON "private"."push_outbox" USING "btree" ("id") WHERE ("sent_at" IS NULL);



CREATE INDEX "beer_prices_venue_id_idx" ON "public"."beer_prices" USING "btree" ("venue_id");



CREATE INDEX "beer_prices_venue_idx" ON "public"."beer_prices" USING "btree" ("venue_id", "created_at" DESC);



CREATE INDEX "beverage_barcode_submissions_sig_idx" ON "public"."beverage_barcode_submissions" USING "btree" ("barcode", "content_sig");



CREATE INDEX "business_boosts_live_idx" ON "public"."business_boosts" USING "btree" ("status") WHERE ("status" = 'live'::"text");



CREATE INDEX "business_card_deliveries_user_idx" ON "public"."business_card_deliveries" USING "btree" ("user_id", "delivered_at" DESC);



CREATE INDEX "business_events_business_idx" ON "public"."business_events" USING "btree" ("business_id", "starts_at");



CREATE INDEX "business_follows_business_idx" ON "public"."business_follows" USING "btree" ("business_id");



CREATE UNIQUE INDEX "business_orders_apple_txn_uq" ON "public"."business_orders" USING "btree" ("apple_transaction_id") WHERE ("apple_transaction_id" IS NOT NULL);



CREATE INDEX "business_orders_business_idx" ON "public"."business_orders" USING "btree" ("business_id", "created_at" DESC);



CREATE INDEX "business_post_comments_post_idx" ON "public"."business_post_comments" USING "btree" ("post_id", "created_at");



CREATE INDEX "business_posts_business_idx" ON "public"."business_posts" USING "btree" ("business_id", "created_at" DESC);



CREATE INDEX "business_push_receipts_user_idx" ON "public"."business_push_receipts" USING "btree" ("user_id", "sent_at" DESC);



CREATE INDEX "businesses_owner_idx" ON "public"."businesses" USING "btree" ("owner_id");



CREATE UNIQUE INDEX "businesses_venue_live_uq" ON "public"."businesses" USING "btree" ("venue_id") WHERE ("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'suspended'::"text"]));



CREATE INDEX "device_tokens_user_id_idx" ON "public"."device_tokens" USING "btree" ("user_id");



CREATE INDEX "dm_messages_recipient_idx" ON "public"."dm_messages" USING "btree" ("recipient_id", "created_at" DESC);



CREATE INDEX "dm_messages_sender_idx" ON "public"."dm_messages" USING "btree" ("sender_id", "created_at" DESC);



CREATE INDEX "event_members_profile_idx" ON "public"."event_members" USING "btree" ("profile_id", "status");



CREATE INDEX "friendships_addressee_idx" ON "public"."friendships" USING "btree" ("addressee_id", "status");



CREATE INDEX "friendships_requester_idx" ON "public"."friendships" USING "btree" ("requester_id", "status");



CREATE INDEX "game_rounds_session_idx" ON "public"."game_rounds" USING "btree" ("session_id", "created_at" DESC);



CREATE INDEX "idx_contact_keys_hash" ON "public"."contact_keys" USING "btree" ("key_hash");



CREATE INDEX "idx_dm_messages_updated_at" ON "public"."dm_messages" USING "btree" ("updated_at");



CREATE INDEX "idx_venues_country" ON "public"."venues" USING "btree" ("country");



CREATE INDEX "invites_recipient_pending_idx" ON "public"."invites" USING "btree" ("recipient_id", "created_at" DESC) WHERE ("status" = 'pending'::"text");



CREATE INDEX "list_requests_business_night" ON "public"."list_requests" USING "btree" ("business_id", "night");



CREATE INDEX "live_stories_created_idx" ON "public"."live_stories" USING "btree" ("created_at");



CREATE INDEX "live_stories_live_idx" ON "public"."live_stories" USING "btree" ("created_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE INDEX "live_stories_profile_idx" ON "public"."live_stories" USING "btree" ("profile_id");



CREATE INDEX "post_comments_post_idx" ON "public"."post_comments" USING "btree" ("post_id", "created_at");



CREATE INDEX "posts_author_idx" ON "public"."posts" USING "btree" ("author_id", "created_at" DESC);



CREATE INDEX "posts_feed_idx" ON "public"."posts" USING "btree" ("created_at" DESC);



CREATE INDEX "posts_live_idx" ON "public"."posts" USING "btree" ("created_at" DESC) WHERE ("deleted_at" IS NULL);



CREATE INDEX "profiles_business_idx" ON "public"."profiles" USING "btree" ("business_id");



CREATE UNIQUE INDEX "profiles_username_lower_idx" ON "public"."profiles" USING "btree" ("lower"("username"));



CREATE INDEX "reports_open_idx" ON "public"."reports" USING "btree" ("created_at" DESC) WHERE ("resolved_at" IS NULL);



CREATE INDEX "session_drinks_live_idx" ON "public"."session_drinks" USING "btree" ("session_id", "live");



CREATE INDEX "session_drinks_session_idx" ON "public"."session_drinks" USING "btree" ("session_id", "created_at");



CREATE INDEX "session_members_session_in_live_idx" ON "public"."session_members" USING "btree" ("session_id") WHERE "in_live";



CREATE INDEX "session_members_session_in_plan_idx" ON "public"."session_members" USING "btree" ("session_id") WHERE "in_plan";



CREATE INDEX "session_snaps_created_idx" ON "public"."session_snaps" USING "btree" ("created_at");



CREATE INDEX "session_snaps_session_idx" ON "public"."session_snaps" USING "btree" ("session_id");



CREATE INDEX "session_stops_session_idx" ON "public"."session_stops" USING "btree" ("session_id");



CREATE INDEX "speakeasy_matches_session_idx" ON "public"."speakeasy_matches" USING "btree" ("session_id", "created_at" DESC);



CREATE INDEX "venue_campaigns_venue_idx" ON "public"."venue_campaigns" USING "btree" ("venue_id");



CREATE INDEX "venue_offers_business_idx" ON "public"."venue_offers" USING "btree" ("business_id");



CREATE INDEX "venue_offers_live_idx" ON "public"."venue_offers" USING "btree" ("is_active", "approved") WHERE ("is_active" AND "approved");



CREATE INDEX "venue_offers_venue_idx" ON "public"."venue_offers" USING "btree" ("venue_id");



CREATE INDEX "venue_specials_venue_idx" ON "public"."venue_specials" USING "btree" ("venue_id");



CREATE INDEX "venues_featured_idx" ON "public"."venues" USING "btree" ("is_featured") WHERE ("is_featured" = true);



CREATE INDEX "venues_geo_idx" ON "public"."venues" USING "btree" ("lat", "lon");



CREATE INDEX "venues_outdoor_seating_idx" ON "public"."venues" USING "btree" ("city", "name") WHERE ("outdoor_seating" = true);



CREATE INDEX "venues_prominence_idx" ON "public"."venues" USING "btree" ("prominence" DESC);



CREATE UNIQUE INDEX "venues_source_external_idx" ON "public"."venues" USING "btree" ("source", "external_id") WHERE ("external_id" IS NOT NULL);



CREATE UNIQUE INDEX "venues_unique_mapkit_id" ON "public"."venues" USING "btree" ("mapkit_id") WHERE ("mapkit_id" IS NOT NULL);



CREATE INDEX "venues_updated_at_idx" ON "public"."venues" USING "btree" ("updated_at");



CREATE OR REPLACE TRIGGER "session_live_ended" AFTER UPDATE OF "active_live" ON "public"."sessions" FOR EACH ROW EXECUTE FUNCTION "private"."on_session_live_ended"();



CREATE OR REPLACE TRIGGER "trg_beer_prices_normalize_serving" BEFORE INSERT OR UPDATE OF "serving" ON "public"."beer_prices" FOR EACH ROW EXECUTE FUNCTION "public"."beer_prices_normalize_serving"();



CREATE OR REPLACE TRIGGER "trg_business_offer_notify" AFTER INSERT ON "public"."venue_offers" FOR EACH ROW WHEN (("new"."business_id" IS NOT NULL)) EXECUTE FUNCTION "public"."on_business_offer_notify"();



CREATE OR REPLACE TRIGGER "trg_business_post_notify" AFTER INSERT ON "public"."business_posts" FOR EACH ROW EXECUTE FUNCTION "public"."on_business_post_notify"();



CREATE OR REPLACE TRIGGER "trg_comment_notify" AFTER INSERT ON "public"."post_comments" FOR EACH ROW EXECUTE FUNCTION "public"."on_comment_notify"();



CREATE OR REPLACE TRIGGER "trg_dm_messages_touch_updated_at" BEFORE UPDATE ON "public"."dm_messages" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_dm_notify" AFTER INSERT ON "public"."dm_messages" FOR EACH ROW EXECUTE FUNCTION "public"."on_dm_notify"();



CREATE OR REPLACE TRIGGER "trg_event_invite_notify" AFTER INSERT ON "public"."event_members" FOR EACH ROW EXECUTE FUNCTION "public"."on_event_invite_notify"();



CREATE OR REPLACE TRIGGER "trg_event_rsvp_notify" AFTER UPDATE ON "public"."event_members" FOR EACH ROW EXECUTE FUNCTION "public"."on_event_rsvp_notify"();



CREATE OR REPLACE TRIGGER "trg_friend_notify" AFTER INSERT ON "public"."friendships" FOR EACH ROW EXECUTE FUNCTION "public"."on_friend_request_notify"();



CREATE OR REPLACE TRIGGER "trg_invite_notify" AFTER INSERT ON "public"."invites" FOR EACH ROW EXECUTE FUNCTION "public"."on_invite_notify"();



CREATE OR REPLACE TRIGGER "trg_like_notify" AFTER INSERT ON "public"."post_likes" FOR EACH ROW EXECUTE FUNCTION "public"."on_like_notify"();



CREATE OR REPLACE TRIGGER "trg_live_presence_notify" AFTER INSERT ON "public"."live_presence" FOR EACH ROW EXECUTE FUNCTION "public"."on_live_presence_notify"();



CREATE OR REPLACE TRIGGER "trg_post_notify" AFTER INSERT ON "public"."posts" FOR EACH ROW EXECUTE FUNCTION "public"."on_post_notify"();



CREATE OR REPLACE TRIGGER "trg_story_notify" AFTER INSERT ON "public"."live_stories" FOR EACH ROW EXECUTE FUNCTION "public"."on_story_notify"();



CREATE OR REPLACE TRIGGER "trg_sync_venue_tier" AFTER INSERT OR DELETE OR UPDATE ON "public"."venue_offers" FOR EACH ROW EXECUTE FUNCTION "public"."sync_venue_tier"();



CREATE OR REPLACE TRIGGER "trg_venues_touch_updated_at" BEFORE UPDATE ON "public"."venues" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "venue_specials_curated_only_trg" BEFORE INSERT OR UPDATE ON "public"."venue_specials" FOR EACH ROW EXECUTE FUNCTION "public"."venue_specials_curated_only"();



ALTER TABLE ONLY "private"."weekend_push_log"
    ADD CONSTRAINT "weekend_push_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_admins"
    ADD CONSTRAINT "app_admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."app_feedback"
    ADD CONSTRAINT "app_feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."beer_prices"
    ADD CONSTRAINT "beer_prices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."beer_prices"
    ADD CONSTRAINT "beer_prices_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."beverage_barcode_submissions"
    ADD CONSTRAINT "beverage_barcode_submissions_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."beverage_barcodes"
    ADD CONSTRAINT "beverage_barcodes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_blocked_id_fkey" FOREIGN KEY ("blocked_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_blocker_id_fkey" FOREIGN KEY ("blocker_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_boosts"
    ADD CONSTRAINT "business_boosts_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_boosts"
    ADD CONSTRAINT "business_boosts_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."business_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_card_deliveries"
    ADD CONSTRAINT "business_card_deliveries_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."business_cards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_card_deliveries"
    ADD CONSTRAINT "business_card_deliveries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_cards"
    ADD CONSTRAINT "business_cards_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_cards"
    ADD CONSTRAINT "business_cards_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."venue_offers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_events"
    ADD CONSTRAINT "business_events_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_follows"
    ADD CONSTRAINT "business_follows_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_follows"
    ADD CONSTRAINT "business_follows_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."business_cards"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."venue_offers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."business_products"("product_id");



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_push_id_fkey" FOREIGN KEY ("push_id") REFERENCES "public"."business_pushes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_orders"
    ADD CONSTRAINT "business_orders_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."business_post_comments"
    ADD CONSTRAINT "business_post_comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."business_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_post_comments"
    ADD CONSTRAINT "business_post_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_post_likes"
    ADD CONSTRAINT "business_post_likes_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."business_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_post_likes"
    ADD CONSTRAINT "business_post_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_posts"
    ADD CONSTRAINT "business_posts_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_posts"
    ADD CONSTRAINT "business_posts_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."venue_offers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_push_receipts"
    ADD CONSTRAINT "business_push_receipts_push_id_fkey" FOREIGN KEY ("push_id") REFERENCES "public"."business_pushes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_push_receipts"
    ADD CONSTRAINT "business_push_receipts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_pushes"
    ADD CONSTRAINT "business_pushes_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_pushes"
    ADD CONSTRAINT "business_pushes_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."venue_offers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_subscription_log"
    ADD CONSTRAINT "business_subscription_log_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."contact_keys"
    ADD CONSTRAINT "contact_keys_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_list_request_id_fkey" FOREIGN KEY ("list_request_id") REFERENCES "public"."list_requests"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_story_id_fkey" FOREIGN KEY ("story_id") REFERENCES "public"."live_stories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_members"
    ADD CONSTRAINT "event_members_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_members"
    ADD CONSTRAINT "event_members_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."event_members"
    ADD CONSTRAINT "event_members_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_live_session_id_fkey" FOREIGN KEY ("live_session_id") REFERENCES "public"."sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_addressee_id_fkey" FOREIGN KEY ("addressee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_requester_id_fkey" FOREIGN KEY ("requester_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_guest_flags"
    ADD CONSTRAINT "list_guest_flags_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_guest_flags"
    ADD CONSTRAINT "list_guest_flags_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_requests"
    ADD CONSTRAINT "list_requests_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."list_requests"
    ADD CONSTRAINT "list_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_presence"
    ADD CONSTRAINT "live_presence_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."live_presence"
    ADD CONSTRAINT "live_presence_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_stories"
    ADD CONSTRAINT "live_stories_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_comments"
    ADD CONSTRAINT "post_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_comments"
    ADD CONSTRAINT "post_comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_likes"
    ADD CONSTRAINT "post_likes_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_likes"
    ADD CONSTRAINT "post_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_target_user_id_fkey" FOREIGN KEY ("target_user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."session_drinks"
    ADD CONSTRAINT "session_drinks_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_drinks"
    ADD CONSTRAINT "session_drinks_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_members"
    ADD CONSTRAINT "session_members_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_members"
    ADD CONSTRAINT "session_members_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_snaps"
    ADD CONSTRAINT "session_snaps_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_snaps"
    ADD CONSTRAINT "session_snaps_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_stops"
    ADD CONSTRAINT "session_stops_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."session_stops"
    ADD CONSTRAINT "session_stops_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_current_venue_id_fkey" FOREIGN KEY ("current_venue_id") REFERENCES "public"."venues"("id");



ALTER TABLE ONLY "public"."sessions"
    ADD CONSTRAINT "sessions_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speakeasy_matches"
    ADD CONSTRAINT "speakeasy_matches_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."speakeasy_matches"
    ADD CONSTRAINT "speakeasy_matches_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."story_views"
    ADD CONSTRAINT "story_views_story_id_fkey" FOREIGN KEY ("story_id") REFERENCES "public"."live_stories"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."story_views"
    ADD CONSTRAINT "story_views_viewer_id_fkey" FOREIGN KEY ("viewer_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_campaigns"
    ADD CONSTRAINT "venue_campaigns_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_canonical"
    ADD CONSTRAINT "venue_canonical_canonical_id_fkey" FOREIGN KEY ("canonical_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_canonical"
    ADD CONSTRAINT "venue_canonical_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_offers"
    ADD CONSTRAINT "venue_offers_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_offers"
    ADD CONSTRAINT "venue_offers_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_push_log"
    ADD CONSTRAINT "venue_push_log_offer_id_fkey" FOREIGN KEY ("offer_id") REFERENCES "public"."venue_offers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."venue_push_log"
    ADD CONSTRAINT "venue_push_log_sent_by_fkey" FOREIGN KEY ("sent_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."venue_push_log"
    ADD CONSTRAINT "venue_push_log_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_requests"
    ADD CONSTRAINT "venue_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_requests"
    ADD CONSTRAINT "venue_requests_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_specials"
    ADD CONSTRAINT "venue_specials_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_sun_facade_reports"
    ADD CONSTRAINT "venue_sun_facade_reports_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_sun_facade_reports"
    ADD CONSTRAINT "venue_sun_facade_reports_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."venue_sun"
    ADD CONSTRAINT "venue_sun_venue_id_fkey" FOREIGN KEY ("venue_id") REFERENCES "public"."venues"("id") ON DELETE CASCADE;



ALTER TABLE "private"."push_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."announcements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_admins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_admins_select" ON "public"."app_admins" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."app_feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."beer_prices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "beer_prices_delete" ON "public"."beer_prices" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "beer_prices_insert" ON "public"."beer_prices" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "beer_prices_read" ON "public"."beer_prices" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."beverage_barcode_submissions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "beverage_barcode_submissions_select_own" ON "public"."beverage_barcode_submissions" FOR SELECT TO "authenticated" USING (("submitted_by" = "auth"."uid"()));



ALTER TABLE "public"."beverage_barcodes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "beverage_barcodes_read" ON "public"."beverage_barcodes" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."blocks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "blocks_self_all" ON "public"."blocks" TO "authenticated" USING (("blocker_id" = "auth"."uid"())) WITH CHECK (("blocker_id" = "auth"."uid"()));



ALTER TABLE "public"."business_boosts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_card_deliveries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_cards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_follows" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "business_follows_own" ON "public"."business_follows" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."business_limits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "business_limits_read" ON "public"."business_limits" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."business_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_post_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_post_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_products" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "business_products_read" ON "public"."business_products" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."business_push_receipts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_pushes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_subscription_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."businesses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "businesses_owner_select" ON "public"."businesses" FOR SELECT TO "authenticated" USING ((("owner_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."app_admins" "a"
  WHERE ("a"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."campaign_stats" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "campaign_stats_admin_select" ON "public"."campaign_stats" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."app_admins"
  WHERE ("app_admins"."user_id" = "auth"."uid"()))));



CREATE POLICY "contact keys: self delete" ON "public"."contact_keys" FOR DELETE USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "contact keys: self read" ON "public"."contact_keys" FOR SELECT USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "contact keys: self write" ON "public"."contact_keys" FOR INSERT WITH CHECK (("profile_id" = "auth"."uid"()));



ALTER TABLE "public"."contact_keys" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."device_tokens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "device_tokens_delete_own" ON "public"."device_tokens" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "device_tokens_select_own" ON "public"."device_tokens" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "dm_insert" ON "public"."dm_messages" FOR INSERT TO "authenticated" WITH CHECK ((("sender_id" = "auth"."uid"()) AND ("sender_id" <> "recipient_id") AND ("kind" <> 'list_request'::"text") AND "public"."dm_can_message"("recipient_id")));



ALTER TABLE "public"."dm_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dm_select" ON "public"."dm_messages" FOR SELECT USING ((("sender_id" = "auth"."uid"()) OR ("recipient_id" = "auth"."uid"())));



CREATE POLICY "dm_update_read" ON "public"."dm_messages" FOR UPDATE USING (("recipient_id" = "auth"."uid"())) WITH CHECK (("recipient_id" = "auth"."uid"()));



CREATE POLICY "drinks: members read" ON "public"."session_drinks" FOR SELECT USING ("public"."is_session_member"("session_id"));



CREATE POLICY "drinks: self delete" ON "public"."session_drinks" FOR DELETE USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "drinks: self insert" ON "public"."session_drinks" FOR INSERT WITH CHECK ((("profile_id" = "auth"."uid"()) AND "public"."is_session_member"("session_id")));



CREATE POLICY "drinks: self update" ON "public"."session_drinks" FOR UPDATE USING (("profile_id" = "auth"."uid"())) WITH CHECK (("profile_id" = "auth"."uid"()));



ALTER TABLE "public"."event_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "event_members_select" ON "public"."event_members" FOR SELECT USING ((("profile_id" = "auth"."uid"()) OR "public"."is_event_member"("event_id", "auth"."uid"())));



ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "events_select" ON "public"."events" FOR SELECT USING ((("host_id" = "auth"."uid"()) OR "public"."is_event_member"("id", "auth"."uid"())));



ALTER TABLE "public"."friendships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "friendships_select_own" ON "public"."friendships" FOR SELECT TO "authenticated" USING ((("requester_id" = "auth"."uid"()) OR ("addressee_id" = "auth"."uid"())));



ALTER TABLE "public"."game_rounds" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "game_rounds host insert" ON "public"."game_rounds" FOR INSERT TO "authenticated" WITH CHECK ((("host_id" = "auth"."uid"()) AND "public"."is_session_member"("session_id")));



CREATE POLICY "game_rounds host select" ON "public"."game_rounds" FOR SELECT TO "authenticated" USING (("host_id" = "auth"."uid"()));



CREATE POLICY "game_rounds host update" ON "public"."game_rounds" FOR UPDATE TO "authenticated" USING (("host_id" = "auth"."uid"())) WITH CHECK (("host_id" = "auth"."uid"()));



ALTER TABLE "public"."invites" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invites_insert_as_sender" ON "public"."invites" FOR INSERT TO "authenticated" WITH CHECK ((("sender_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."session_members" "sm"
  WHERE (("sm"."session_id" = "invites"."session_id") AND ("sm"."profile_id" = "auth"."uid"()) AND ("sm"."in_plan" OR "sm"."in_live"))))));



CREATE POLICY "invites_select_own" ON "public"."invites" FOR SELECT TO "authenticated" USING ((("recipient_id" = "auth"."uid"()) OR ("sender_id" = "auth"."uid"())));



CREATE POLICY "invites_update_recipient" ON "public"."invites" FOR UPDATE TO "authenticated" USING (("recipient_id" = "auth"."uid"())) WITH CHECK (("recipient_id" = "auth"."uid"()));



CREATE POLICY "invites_update_sender" ON "public"."invites" FOR UPDATE TO "authenticated" USING (("sender_id" = "auth"."uid"())) WITH CHECK (("sender_id" = "auth"."uid"()));



ALTER TABLE "public"."list_guest_flags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "list_guest_flags_select" ON "public"."list_guest_flags" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."business_id" = "list_guest_flags"."business_id")))));



ALTER TABLE "public"."list_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "list_requests_select" ON "public"."list_requests" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."business_id" = "list_requests"."business_id"))))));



ALTER TABLE "public"."live_presence" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "live_presence_self_delete" ON "public"."live_presence" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "live_presence_self_insert" ON "public"."live_presence" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "live_presence_self_select" ON "public"."live_presence" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "live_presence_self_update" ON "public"."live_presence" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."live_stories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "live_stories_friends_select" ON "public"."live_stories" FOR SELECT TO "authenticated" USING ((("deleted_at" IS NULL) AND ("created_at" > ("now"() - '24:00:00'::interval)) AND (("profile_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."friendships" "fr"
  WHERE (("fr"."status" = 'accepted'::"text") AND ((("fr"."requester_id" = "auth"."uid"()) AND ("fr"."addressee_id" = "live_stories"."profile_id")) OR (("fr"."addressee_id" = "auth"."uid"()) AND ("fr"."requester_id" = "live_stories"."profile_id")))))))));



CREATE POLICY "live_stories_self_delete" ON "public"."live_stories" FOR DELETE TO "authenticated" USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "live_stories_self_insert" ON "public"."live_stories" FOR INSERT TO "authenticated" WITH CHECK (("profile_id" = "auth"."uid"()));



CREATE POLICY "members: read peers" ON "public"."session_members" FOR SELECT USING ("public"."is_session_member"("session_id"));



CREATE POLICY "members: self delete" ON "public"."session_members" FOR DELETE USING (("profile_id" = "auth"."uid"()));



CREATE POLICY "members: self insert" ON "public"."session_members" FOR INSERT WITH CHECK ((("profile_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."sessions" "s"
  WHERE (("s"."id" = "session_members"."session_id") AND ("s"."host_id" = "auth"."uid"()))))));



ALTER TABLE "public"."post_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."post_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "posts_delete_own" ON "public"."posts" FOR DELETE TO "authenticated" USING (("author_id" = "auth"."uid"()));



CREATE POLICY "posts_insert_own" ON "public"."posts" FOR INSERT TO "authenticated" WITH CHECK (("author_id" = "auth"."uid"()));



CREATE POLICY "posts_select_own" ON "public"."posts" FOR SELECT TO "authenticated" USING (("author_id" = "auth"."uid"()));



CREATE POLICY "posts_update_own" ON "public"."posts" FOR UPDATE TO "authenticated" USING (("author_id" = "auth"."uid"())) WITH CHECK (("author_id" = "auth"."uid"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles: read friends" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."friendships" "f"
  WHERE (("f"."status" = 'accepted'::"text") AND ((("f"."requester_id" = "auth"."uid"()) AND ("f"."addressee_id" = "profiles"."id")) OR (("f"."requester_id" = "profiles"."id") AND ("f"."addressee_id" = "auth"."uid"())))))));



CREATE POLICY "profiles: read session peers" ON "public"."profiles" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."session_members" "m1"
     JOIN "public"."session_members" "m2" ON (("m1"."session_id" = "m2"."session_id")))
  WHERE (("m1"."profile_id" = "auth"."uid"()) AND ("m2"."profile_id" = "profiles"."id")))));



CREATE POLICY "profiles_insert_own" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "profiles_select_own" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reports_admin_select" ON "public"."reports" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."app_admins"
  WHERE ("app_admins"."user_id" = "auth"."uid"()))));



CREATE POLICY "reports_insert_self" ON "public"."reports" FOR INSERT TO "authenticated" WITH CHECK (("reporter_id" = "auth"."uid"()));



ALTER TABLE "public"."session_drinks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_drinks_delete_member" ON "public"."session_drinks" FOR DELETE TO "authenticated" USING ((("profile_id" = "auth"."uid"()) OR (("shared" = true) AND (EXISTS ( SELECT 1
   FROM "public"."session_members" "sm"
  WHERE (("sm"."session_id" = "session_drinks"."session_id") AND ("sm"."profile_id" = "auth"."uid"())))))));



ALTER TABLE "public"."session_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_members_update_own" ON "public"."session_members" FOR UPDATE TO "authenticated" USING (("profile_id" = "auth"."uid"())) WITH CHECK (("profile_id" = "auth"."uid"()));



ALTER TABLE "public"."session_snaps" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_snaps_member_select" ON "public"."session_snaps" FOR SELECT TO "authenticated" USING ("public"."is_session_member"("session_id"));



CREATE POLICY "session_snaps_self_delete" ON "public"."session_snaps" FOR DELETE TO "authenticated" USING ((("profile_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."sessions" "s"
  WHERE (("s"."id" = "session_snaps"."session_id") AND ("s"."host_id" = "auth"."uid"()))))));



CREATE POLICY "session_snaps_self_insert" ON "public"."session_snaps" FOR INSERT TO "authenticated" WITH CHECK ((("profile_id" = "auth"."uid"()) AND "public"."is_session_member"("session_id")));



ALTER TABLE "public"."session_stops" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_stops_member_insert" ON "public"."session_stops" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_session_member"("session_id"));



CREATE POLICY "session_stops_member_select" ON "public"."session_stops" FOR SELECT TO "authenticated" USING ("public"."is_session_member"("session_id"));



CREATE POLICY "session_stops_member_update" ON "public"."session_stops" FOR UPDATE TO "authenticated" USING ("public"."is_session_member"("session_id")) WITH CHECK ("public"."is_session_member"("session_id"));



ALTER TABLE "public"."sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sessions: host insert" ON "public"."sessions" FOR INSERT WITH CHECK (("host_id" = "auth"."uid"()));



CREATE POLICY "sessions: host update" ON "public"."sessions" FOR UPDATE USING (("host_id" = "auth"."uid"())) WITH CHECK (("host_id" = "auth"."uid"()));



CREATE POLICY "sessions: members read" ON "public"."sessions" FOR SELECT USING (("public"."is_session_member"("id") OR ("host_id" = "auth"."uid"())));



CREATE POLICY "sessions_update_host" ON "public"."sessions" FOR UPDATE TO "authenticated" USING (("host_id" = "auth"."uid"())) WITH CHECK (("host_id" = "auth"."uid"()));



ALTER TABLE "public"."speakeasy_matches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."story_views" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "story_views_insert_self" ON "public"."story_views" FOR INSERT TO "authenticated" WITH CHECK ((("viewer_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."live_stories" "s"
  WHERE ("s"."id" = "story_views"."story_id")))));



CREATE POLICY "story_views_select" ON "public"."story_views" FOR SELECT TO "authenticated" USING ((("viewer_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."live_stories" "s"
  WHERE (("s"."id" = "story_views"."story_id") AND ("s"."profile_id" = "auth"."uid"()))))));



ALTER TABLE "public"."venue_campaigns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_campaigns_select" ON "public"."venue_campaigns" FOR SELECT TO "authenticated" USING (("is_active" AND "approved" AND (("starts_at" IS NULL) OR ("starts_at" <= "now"())) AND (("ends_at" IS NULL) OR ("ends_at" >= "now"())) AND (EXISTS ( SELECT 1
   FROM "public"."venues" "v"
  WHERE (("v"."id" = "venue_campaigns"."venue_id") AND
        CASE "venue_campaigns"."placement"
            WHEN 'poster'::"text" THEN ("v"."tier" = ANY (ARRAY['poster'::"text", 'billboard'::"text"]))
            ELSE ("v"."tier" = 'billboard'::"text")
        END)))));



ALTER TABLE "public"."venue_canonical" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_canonical_select" ON "public"."venue_canonical" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."venue_offers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_offers_read" ON "public"."venue_offers" FOR SELECT TO "authenticated" USING (("is_active" AND "approved" AND (("starts_at" IS NULL) OR ("starts_at" <= "now"())) AND (("ends_at" IS NULL) OR ("ends_at" > "now"()))));



ALTER TABLE "public"."venue_push_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_push_log_admin_select" ON "public"."venue_push_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."app_admins"
  WHERE ("app_admins"."user_id" = "auth"."uid"()))));



ALTER TABLE "public"."venue_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_requests_select_own" ON "public"."venue_requests" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."venue_specials" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_specials_read_all" ON "public"."venue_specials" FOR SELECT USING (true);



ALTER TABLE "public"."venue_sun" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."venue_sun_facade_reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venue_sun_read" ON "public"."venue_sun" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."venues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "venues_insert_non_curated" ON "public"."venues" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."uid"() IS NOT NULL) AND ("source" = ANY (ARRAY['mapkit'::"text", 'user'::"text"]))));



CREATE POLICY "venues_read_all" ON "public"."venues" FOR SELECT USING (true);



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON TABLE "public"."business_products" TO "anon";
GRANT ALL ON TABLE "public"."business_products" TO "authenticated";
GRANT ALL ON TABLE "public"."business_products" TO "service_role";



GRANT ALL ON TABLE "public"."businesses" TO "anon";
GRANT ALL ON TABLE "public"."businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."businesses" TO "service_role";



GRANT ALL ON TABLE "public"."speakeasy_matches" TO "service_role";



REVOKE ALL ON FUNCTION "public"."add_comment"("p_post_id" "uuid", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_comment"("p_post_id" "uuid", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_comment"("p_post_id" "uuid", "p_body" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_app_feedback"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_app_feedback"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_apply_mapkit_ids"("p_pairs" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_apply_mapkit_ids"("p_pairs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_apply_mapkit_ids"("p_pairs" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_business_queue"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_business_queue"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."admin_business_set_status"("p_business" "uuid", "p_status" "text", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_business_set_status"("p_business" "uuid", "p_status" "text", "p_note" "text") TO "authenticated";



GRANT ALL ON TABLE "public"."venue_campaigns" TO "anon";
GRANT ALL ON TABLE "public"."venue_campaigns" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_campaigns" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_campaign"("p_venue" "uuid", "p_placement" "text", "p_title" "text", "p_body" "text", "p_cta" "text", "p_image_url" "text", "p_starts" timestamp with time zone, "p_ends" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_campaign"("p_venue" "uuid", "p_placement" "text", "p_title" "text", "p_body" "text", "p_cta" "text", "p_image_url" "text", "p_starts" timestamp with time zone, "p_ends" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_campaign"("p_venue" "uuid", "p_placement" "text", "p_title" "text", "p_body" "text", "p_cta" "text", "p_image_url" "text", "p_starts" timestamp with time zone, "p_ends" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_offer"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_redeem" "text", "p_code" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_offer"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_redeem" "text", "p_code" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_offer"("p_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_redeem" "text", "p_code" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_campaign"("p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_campaign"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_campaign"("p_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_delete_offer"("p_offer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_offer"("p_offer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_offer"("p_offer_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_list_campaigns"() TO "anon";
GRANT ALL ON FUNCTION "public"."admin_list_campaigns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_campaigns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_list_offers"() TO "anon";
GRANT ALL ON FUNCTION "public"."admin_list_offers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_offers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_order_decide"("p_order" "uuid", "p_action" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_order_decide"("p_order" "uuid", "p_action" "text", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_report_resolve"("p_report" "uuid", "p_action" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_report_resolve"("p_report" "uuid", "p_action" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_report_resolve"("p_report" "uuid", "p_action" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_reports"("p_include_resolved" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reports"("p_include_resolved" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_reports"("p_include_resolved" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_restore"("p_kind" "text", "p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_restore"("p_kind" "text", "p_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_restore"("p_kind" "text", "p_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_send_announcement"("p_title" "text", "p_body" "text", "p_dry_run" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_send_announcement"("p_title" "text", "p_body" "text", "p_dry_run" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_send_announcement"("p_title" "text", "p_body" "text", "p_dry_run" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_business_limit"("p_key" "text", "p_value" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_set_business_limit"("p_key" "text", "p_value" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."admin_set_business_product_price"("p_product_id" "text", "p_amount" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_set_business_product_price"("p_product_id" "text", "p_amount" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."admin_set_campaign_active"("p_id" "uuid", "p_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_campaign_active"("p_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_campaign_active"("p_id" "uuid", "p_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_venue_sun"("p_venue" "uuid", "p_mode" "text", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_venue_sun"("p_venue" "uuid", "p_mode" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_venue_sun"("p_venue" "uuid", "p_mode" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_venue_tier"("p_venue" "uuid", "p_tier" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_venue_tier"("p_venue" "uuid", "p_tier" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_venue_tier"("p_venue" "uuid", "p_tier" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_takedown"("p_kind" "text", "p_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_takedown"("p_kind" "text", "p_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_takedown"("p_kind" "text", "p_id" "uuid", "p_reason" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."admin_update_offer"("p_offer_id" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_offer"("p_offer_id" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_offer"("p_offer_id" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_placement" "text", "p_image_url" "text", "p_billboard_image_url" "text", "p_interstitial" boolean, "p_show_on_valid_only" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_venue_requests"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_venue_requests"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_venue_requests"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."agreed_facade_bearing"("p_venue" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."app_feedback_add"("p_message" "text", "p_build" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."app_feedback_add"("p_message" "text", "p_build" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."appstore_apply"("p_fact" "jsonb", "p_status" integer, "p_paid" boolean, "p_notification" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."appstore_apply"("p_fact" "jsonb", "p_status" integer, "p_paid" boolean, "p_notification" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."auto_recalc_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."auto_recalc_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_recalc_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bars_near"("p_lat" double precision, "p_lon" double precision, "p_km" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."beer_prices_normalize_serving"() TO "anon";
GRANT ALL ON FUNCTION "public"."beer_prices_normalize_serving"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."beer_prices_normalize_serving"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_user"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_user"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."block_user"("p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."boosts_live"() TO "service_role";
GRANT ALL ON FUNCTION "public"."boosts_live"() TO "anon";
GRANT ALL ON FUNCTION "public"."boosts_live"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."bump_campaign_stats"("p_campaign" "uuid", "p_impressions" integer, "p_taps" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."bump_campaign_stats"("p_campaign" "uuid", "p_impressions" integer, "p_taps" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_campaign_stats"("p_campaign" "uuid", "p_impressions" integer, "p_taps" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."business_boost_paid"("p_boost" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_boost_paid"("p_boost" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_by_username"("p_username" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_by_username"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."business_by_username"("p_username" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_cancel_boost"("p_boost" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_cancel_boost"("p_boost" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_cancel_event"("p_event" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_cancel_event"("p_event" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_cancel_order"("p_order" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_cancel_order"("p_order" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_create_boost"("p_post" "uuid", "p_product_id" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_create_boost"("p_post" "uuid", "p_product_id" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_create_deal"("p_business" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_image_url" "text", "p_show_on_valid_only" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_create_deal"("p_business" "uuid", "p_kind" "text", "p_title" "text", "p_description" "text", "p_fine_print" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_active_days" integer[], "p_start_minute" integer, "p_end_minute" integer, "p_image_url" "text", "p_show_on_valid_only" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_create_event"("p_business" "uuid", "p_title" "text", "p_starts_at" timestamp with time zone, "p_image_url" "text", "p_image_ratio" real) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_create_event"("p_business" "uuid", "p_title" "text", "p_starts_at" timestamp with time zone, "p_image_url" "text", "p_image_ratio" real) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_create_post"("p_business" "uuid", "p_image_urls" "text"[], "p_image_ratio" real, "p_caption" "text", "p_event_at" timestamp with time zone, "p_offer" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_create_post"("p_business" "uuid", "p_image_urls" "text"[], "p_image_ratio" real, "p_caption" "text", "p_event_at" timestamp with time zone, "p_offer" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_delete_post"("p_post" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_delete_post"("p_post" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_end_deal"("p_offer" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_end_deal"("p_offer" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_events_upcoming"() TO "service_role";
GRANT ALL ON FUNCTION "public"."business_events_upcoming"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_feed"("p_limit" integer, "p_before" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_feed"("p_limit" integer, "p_before" timestamp with time zone) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_mark_paid"("p_order" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_mark_paid"("p_order" "uuid", "p_transaction_id" "text", "p_product_id" "text", "p_original_transaction_id" "text", "p_jws" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_mine"() TO "service_role";
GRANT ALL ON FUNCTION "public"."business_mine"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_overview"("p_business" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_overview"("p_business" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_post_comment"("p_post" "uuid", "p_body" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_post_comment"("p_post" "uuid", "p_body" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_post_comments"("p_post" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_post_comments"("p_post" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."business_post_comments"("p_post" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_post_delete_comment"("p_comment" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_post_delete_comment"("p_comment" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_post_like"("p_post" "uuid", "p_on" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_post_like"("p_post" "uuid", "p_on" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_profile"("p_business" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_profile"("p_business" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."business_profile"("p_business" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_profiles_public"() TO "service_role";
GRANT ALL ON FUNCTION "public"."business_profiles_public"() TO "anon";
GRANT ALL ON FUNCTION "public"."business_profiles_public"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_qr_token"("p_business" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_qr_token"("p_business" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_register"("p_business_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_org_number" "text", "p_venue_external_id" "text", "p_venue_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_country" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_register"("p_business_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_org_number" "text", "p_venue_external_id" "text", "p_venue_name" "text", "p_address" "text", "p_city" "text", "p_lat" double precision, "p_lon" double precision, "p_country" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_request_card"("p_business" "uuid", "p_offer" "uuid", "p_audience_cap" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_request_card"("p_business" "uuid", "p_offer" "uuid", "p_audience_cap" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_request_push"("p_business" "uuid", "p_offer" "uuid", "p_title" "text", "p_body" "text", "p_audience_cap" integer, "p_send_at" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_request_push"("p_business" "uuid", "p_offer" "uuid", "p_title" "text", "p_body" "text", "p_audience_cap" integer, "p_send_at" timestamp with time zone) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."business_set_list_days"("p_business" "uuid", "p_days" smallint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."business_set_list_days"("p_business" "uuid", "p_days" smallint[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_set_list_days"("p_business" "uuid", "p_days" smallint[]) TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_sync_subscription"("p_business" "uuid", "p_product_id" "text", "p_original_transaction_id" "text", "p_expires_at" timestamp with time zone, "p_transaction_id" "text", "p_jws" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."business_sync_subscription"("p_business" "uuid", "p_product_id" "text", "p_original_transaction_id" "text", "p_expires_at" timestamp with time zone, "p_transaction_id" "text", "p_jws" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."business_update_profile"("p_business" "uuid", "p_logo_url" "text", "p_poster_url" "text", "p_tagline" "text", "p_clear_logo" boolean, "p_clear_poster" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."business_update_profile"("p_business" "uuid", "p_logo_url" "text", "p_poster_url" "text", "p_tagline" "text", "p_clear_logo" boolean, "p_clear_poster" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."can_see_post"("p_post_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_see_post"("p_post_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_event"("p_event" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_event"("p_event" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_event"("p_event" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."city_index"("p_country" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."city_index"("p_country" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."city_index"("p_country" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."city_index"("p_country" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_sponsored_card"("p_lat" double precision, "p_lon" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."claim_sponsored_card"("p_lat" double precision, "p_lon" double precision) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."clear_my_contact_keys"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clear_my_contact_keys"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_my_contact_keys"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_my_contact_keys"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."country_index"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."country_index"() TO "anon";
GRANT ALL ON FUNCTION "public"."country_index"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."country_index"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_event"("p_title" "text", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_duration_hours" numeric, "p_nights" integer, "p_target_bac" numeric, "p_auto_live" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_event"("p_title" "text", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_duration_hours" numeric, "p_nights" integer, "p_target_bac" numeric, "p_auto_live" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_event"("p_title" "text", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_duration_hours" numeric, "p_nights" integer, "p_target_bac" numeric, "p_auto_live" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_account_rows"("p_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_account_rows"("p_uid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_comment"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_comment"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_comment"("p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."disclaimer_ack"("p_version" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."disclaimer_ack"("p_version" "text") TO "authenticated";



GRANT ALL ON FUNCTION "public"."disclaimer_state"() TO "service_role";
GRANT ALL ON FUNCTION "public"."disclaimer_state"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dm_can_message"("p_other" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dm_can_message"("p_other" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."dm_can_message"("p_other" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dm_partners"("p_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dm_partners"("p_ids" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."dm_partners"("p_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."email_for_username"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."email_for_username"("p_username" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_qr_token"("p_venue" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_qr_token"("p_venue" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_qr_token"("p_venue" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."follow_business"("p_business" "uuid", "p_on" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."follow_business"("p_business" "uuid", "p_on" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."friends_feed"("p_limit" integer, "p_before" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."friends_feed"("p_limit" integer, "p_before" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."friends_feed"("p_limit" integer, "p_before" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."friends_live_pulse"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."friends_live_pulse"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."friends_live_pulse"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."game_round_for_session"("p_session" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."game_round_for_session"("p_session" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."game_round_for_session"("p_session" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."grant_admin_by_email"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."grant_admin_by_email"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_admin_by_email"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."haversine_m"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."haversine_m"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."haversine_m"("lat1" double precision, "lon1" double precision, "lat2" double precision, "lon2" double precision) TO "service_role";



REVOKE ALL ON FUNCTION "public"."invite_to_event"("p_event" "uuid", "p_recipients" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invite_to_event"("p_event" "uuid", "p_recipients" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."invite_to_event"("p_event" "uuid", "p_recipients" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_event_host"("p_event" "uuid", "p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_event_host"("p_event" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_event_host"("p_event" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_event_member"("p_event" "uuid", "p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_event_member"("p_event" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_event_member"("p_event" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_session_member"("sid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_session_member"("sid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_session_member"("sid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."join_session_by_code"("code" "text", "mode" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."join_session_by_code"("code" "text", "mode" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."join_session_by_code"("code" "text", "mode" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."leave_event"("p_event" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."leave_event"("p_event" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."leave_event"("p_event" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_comments"("p_post_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_comments"("p_post_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_comments"("p_post_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_friends"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_friends"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_friends"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_guest_flag"("p_business" "uuid", "p_user" "uuid", "p_flag" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_guest_flag"("p_business" "uuid", "p_user" "uuid", "p_flag" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."list_guest_flag"("p_business" "uuid", "p_user" "uuid", "p_flag" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_guest_flags_for"("p_business" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_guest_flags_for"("p_business" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."list_guest_flags_for"("p_business" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_incoming_requests"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_incoming_requests"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_incoming_requests"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_request_decide"("p_request" "uuid", "p_approve" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_request_decide"("p_request" "uuid", "p_approve" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."list_request_decide"("p_request" "uuid", "p_approve" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_request_send"("p_business" "uuid", "p_full_name" "text", "p_instagram" "text", "p_plus" integer, "p_night" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_request_send"("p_business" "uuid", "p_full_name" "text", "p_instagram" "text", "p_plus" integer, "p_night" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."list_request_send"("p_business" "uuid", "p_full_name" "text", "p_instagram" "text", "p_plus" integer, "p_night" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_requests_for"("p_business" "uuid", "p_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_requests_for"("p_business" "uuid", "p_from" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."list_requests_for"("p_business" "uuid", "p_from" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."log_sip"("p_session" "uuid", "p_profile" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_sip"("p_session" "uuid", "p_profile" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."log_sip"("p_session" "uuid", "p_profile" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."match_contacts"("p_hashes" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."match_contacts"("p_hashes" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."match_contacts"("p_hashes" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_contacts"("p_hashes" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_post_activity"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_post_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_post_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_beer_serving"("s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_beer_serving"("s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_beer_serving"("s" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."on_business_offer_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_business_post_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_comment_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_comment_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_comment_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_dm_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_dm_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_dm_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_event_invite_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_event_invite_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_event_invite_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_event_rsvp_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_event_rsvp_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_event_rsvp_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_friend_request_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_friend_request_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_friend_request_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_invite_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_invite_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_invite_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_like_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_like_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_like_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_live_presence_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_post_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_post_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_post_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."on_story_notify"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_story_notify"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_story_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."public_beer_prices"("p_limit" integer, "p_offset" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."public_beer_prices"("p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."public_beer_prices"("p_limit" integer, "p_offset" integer) TO "authenticated";



GRANT ALL ON FUNCTION "public"."public_deals"() TO "anon";
GRANT ALL ON FUNCTION "public"."public_deals"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."public_deals"() TO "service_role";



GRANT ALL ON FUNCTION "public"."public_happy_hour_prices"() TO "service_role";
GRANT ALL ON FUNCTION "public"."public_happy_hour_prices"() TO "anon";
GRANT ALL ON FUNCTION "public"."public_happy_hour_prices"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."purge_rate_limits"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_rate_limits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rate_limit_ceiling"("p_bucket" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rate_limit_ceiling"("p_bucket" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rate_limit_ceiling"("p_bucket" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rate_limit_hit"("p_bucket" "text", "p_key" "text", "p_limit" integer, "p_window" interval) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rate_limit_hit"("p_bucket" "text", "p_key" "text", "p_limit" integer, "p_window" interval) TO "service_role";



REVOKE ALL ON FUNCTION "public"."rate_limit_take"("p_bucket" "text", "p_key" "text", "p_n" integer, "p_limit" integer, "p_window" interval) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rate_limit_take"("p_bucket" "text", "p_key" "text", "p_n" integer, "p_limit" integer, "p_window" interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."recap_display"("p_recap" "jsonb", "p_keep_bac" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."recap_display"("p_recap" "jsonb", "p_keep_bac" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recap_display"("p_recap" "jsonb", "p_keep_bac" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_venue_canonical"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_venue_canonical"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."refresh_venue_prominence"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_venue_prominence"() TO "service_role";



GRANT ALL ON FUNCTION "public"."register_device_token"("p_token" "text", "p_platform" "text", "p_time_zone" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."register_device_token"("p_token" "text", "p_platform" "text", "p_time_zone" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."remove_friend"("p_other" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_friend"("p_other" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_friend"("p_other" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_outdoor_seating"("p_venue" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_outdoor_seating_web"("p_venue" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."report_sun_facade"("p_venue" "uuid", "p_bearing" smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."report_sun_facade"("p_venue" "uuid", "p_bearing" smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_sun_facade"("p_venue" "uuid", "p_bearing" smallint) TO "service_role";



REVOKE ALL ON FUNCTION "public"."request_ip"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_ip"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."respond_friend_request"("p_request_id" "uuid", "p_accept" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."respond_friend_request"("p_request_id" "uuid", "p_accept" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."respond_friend_request"("p_request_id" "uuid", "p_accept" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."respond_to_event"("p_event" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."respond_to_event"("p_event" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."respond_to_event"("p_event" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."review_prompt_state"() TO "service_role";
GRANT ALL ON FUNCTION "public"."review_prompt_state"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."review_prompt_touch"("p_done" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."review_prompt_touch"("p_done" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."revoke_admin"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_admin"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_admin"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."run_event_live_lifecycle"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."run_event_live_lifecycle"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_event_live_lifecycle"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision, "p_lon" double precision, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision, "p_lon" double precision, "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision, "p_lon" double precision, "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_sun_venues"("p_query" "text", "p_lat" double precision, "p_lon" double precision, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."search_usernames"("p_query" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_usernames"("p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_usernames"("p_query" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."send_friend_request"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."send_friend_request"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_friend_request"("p_username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_venue_push"("p_offer_id" "uuid", "p_title" "text", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."send_venue_push"("p_offer_id" "uuid", "p_title" "text", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_venue_push"("p_offer_id" "uuid", "p_title" "text", "p_body" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."session_ghost_drink_add"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."session_ghost_drink_add"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink" "jsonb") TO "authenticated";



GRANT ALL ON FUNCTION "public"."session_ghost_drink_remove"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."session_ghost_drink_remove"("p_session_id" "uuid", "p_ghost_id" "uuid", "p_drink_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."session_ghost_remove"("p_session_id" "uuid", "p_ghost_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."session_ghost_remove"("p_session_id" "uuid", "p_ghost_id" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."session_ghost_upsert"("p_session_id" "uuid", "p_ghost" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."session_ghost_upsert"("p_session_id" "uuid", "p_ghost" "jsonb") TO "authenticated";



GRANT ALL ON FUNCTION "public"."set_business_follow_notify"("p_business" "uuid", "p_on" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."set_business_follow_notify"("p_business" "uuid", "p_on" boolean) TO "authenticated";



GRANT ALL ON FUNCTION "public"."set_deals_location"("p_lat" double precision, "p_lon" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."set_deals_location"("p_lat" double precision, "p_lon" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_deals_location"("p_lat" double precision, "p_lon" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_deals_push_opt_in"("p_on" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_deals_push_opt_in"("p_on" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_deals_push_opt_in"("p_on" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_auto_live"("p_event" "uuid", "p_on" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_auto_live"("p_event" "uuid", "p_on" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_auto_live"("p_event" "uuid", "p_on" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_byo"("p_event" "uuid", "p_items" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_byo"("p_event" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_byo"("p_event" "uuid", "p_items" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_cover"("p_event" "uuid", "p_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_cover"("p_event" "uuid", "p_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_cover"("p_event" "uuid", "p_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_ghosts"("p_event" "uuid", "p_ghosts" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_ghosts"("p_event" "uuid", "p_ghosts" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_ghosts"("p_event" "uuid", "p_ghosts" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_location"("p_event" "uuid", "p_kind" "text", "p_name" "text", "p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_location"("p_event" "uuid", "p_kind" "text", "p_name" "text", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_location"("p_event" "uuid", "p_kind" "text", "p_name" "text", "p_payload" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_modes"("p_event" "uuid", "p_plan_mode" "text", "p_edit_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_modes"("p_event" "uuid", "p_plan_mode" "text", "p_edit_mode" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_modes"("p_event" "uuid", "p_plan_mode" "text", "p_edit_mode" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_event_supplies"("p_event" "uuid", "p_supplies" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_like"("p_post_id" "uuid", "p_like" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_like"("p_post_id" "uuid", "p_like" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_like"("p_post_id" "uuid", "p_like" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_my_contact_keys"("p_keys" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_session_ghosts"("p_session_id" "uuid", "p_ghosts" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_session_ghosts"("p_session_id" "uuid", "p_ghosts" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_session_ghosts"("p_session_id" "uuid", "p_ghosts" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_session_live_loose_spot"("p_session_id" "uuid", "p_spot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_session_live_loose_spot"("p_session_id" "uuid", "p_spot" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_session_live_loose_spot"("p_session_id" "uuid", "p_spot" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_session_live_venue"("p_session_id" "uuid", "p_venue" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_session_live_venue"("p_session_id" "uuid", "p_venue" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_session_live_venue"("p_session_id" "uuid", "p_venue" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_sponsored_cards_opt_out"("p_off" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."set_sponsored_cards_opt_out"("p_off" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_username"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_username"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_username"("p_username" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_venue_time_zone"("p_venue_id" "uuid", "p_zone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_venue_time_zone"("p_venue_id" "uuid", "p_zone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_venue_time_zone"("p_venue_id" "uuid", "p_zone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_weekend_push_opt_in"("p_on" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."set_weekend_push_opt_in"("p_on" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."speakeasy_act"("p_match" "uuid", "p_action" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."speakeasy_act"("p_match" "uuid", "p_action" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."speakeasy_act"("p_match" "uuid", "p_action" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."speakeasy_current"("p_session" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."speakeasy_current"("p_session" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."speakeasy_current"("p_session" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."speakeasy_start"("p_session" "uuid", "p_players" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."speakeasy_start"("p_session" "uuid", "p_players" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."speakeasy_start"("p_session" "uuid", "p_players" "uuid"[]) TO "authenticated";



GRANT ALL ON FUNCTION "public"."sponsored_card_tapped"("p_card" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."sponsored_card_tapped"("p_card" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."submit_beer_price"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_note" "text", "p_serving" "text", "p_currency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_beer_price"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_note" "text", "p_serving" "text", "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_beer_price"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_note" "text", "p_serving" "text", "p_currency" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_beer_price_web"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_serving" "text", "p_currency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_beer_price_web"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_serving" "text", "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_beer_price_web"("p_name" "text", "p_lat" double precision, "p_lon" double precision, "p_external_id" "text", "p_city" "text", "p_address" "text", "p_price" numeric, "p_serving" "text", "p_currency" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_beverage_barcode"("p_barcode" "text", "p_name" "text", "p_category" "text", "p_volume_ml" double precision, "p_abv" double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_beverage_barcode"("p_barcode" "text", "p_name" "text", "p_category" "text", "p_volume_ml" double precision, "p_abv" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_beverage_barcode"("p_barcode" "text", "p_name" "text", "p_category" "text", "p_volume_ml" double precision, "p_abv" double precision) TO "service_role";



REVOKE ALL ON FUNCTION "public"."sun_venue"("p_venue_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sun_venue"("p_venue_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sun_venue"("p_venue_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sun_venue"("p_venue_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."sun_venue_budget_take"("p_n" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sun_venue_budget_take"("p_n" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_venue_tier"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_venue_tier"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_venue_tier"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."unblock_user"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unblock_user"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unblock_user"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_event_plan"("p_event" "uuid", "p_target_bac" numeric, "p_duration_hours" numeric, "p_nights" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_event_plan"("p_event" "uuid", "p_target_bac" numeric, "p_duration_hours" numeric, "p_nights" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_plan"("p_event" "uuid", "p_target_bac" numeric, "p_duration_hours" numeric, "p_nights" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_files"("p_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_files"("p_uid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."user_posts"("p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."user_posts"("p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_posts"("p_user" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."username_available"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."username_available"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."username_available"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."username_available"("p_username" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."venue_beer_prices"("p_limit" integer, "p_offset" integer, "p_country" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_beer_prices"("p_limit" integer, "p_offset" integer, "p_country" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."venue_beer_prices"("p_limit" integer, "p_offset" integer, "p_country" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_beer_prices"("p_limit" integer, "p_offset" integer, "p_country" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."venue_for_qr"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."venue_for_qr"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_for_qr"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."venue_heat"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."venue_heat"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_heat"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision) TO "service_role";



REVOKE ALL ON FUNCTION "public"."venue_request_counts"("p_venues" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_request_counts"("p_venues" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."venue_request_counts"("p_venues" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."venue_request_set"("p_venue" "uuid", "p_on" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_request_set"("p_venue" "uuid", "p_on" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."venue_request_set"("p_venue" "uuid", "p_on" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."venue_requests_mine"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_requests_mine"() TO "service_role";
GRANT ALL ON FUNCTION "public"."venue_requests_mine"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."venue_specials_curated_only"() TO "anon";
GRANT ALL ON FUNCTION "public"."venue_specials_curated_only"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_specials_curated_only"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_sun_by_ids"("p_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer, "p_min_prominence" smallint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer, "p_min_prominence" smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer, "p_min_prominence" smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."venue_sun_map"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer, "p_min_prominence" smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."venues_missing_sun"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."venues_missing_sun"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."venues_missing_sun"("p_lat" double precision, "p_lon" double precision, "p_radius_m" double precision, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."venues_needing_sun"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."venues_needing_sun"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."widmark_bac"("p_events" "jsonb", "p_weight_kg" double precision, "p_sex" "text", "p_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."widmark_bac"("p_events" "jsonb", "p_weight_kg" double precision, "p_sex" "text", "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."widmark_bac"("p_events" "jsonb", "p_weight_kg" double precision, "p_sex" "text", "p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON TABLE "public"."announcements" TO "anon";
GRANT ALL ON TABLE "public"."announcements" TO "authenticated";
GRANT ALL ON TABLE "public"."announcements" TO "service_role";



GRANT ALL ON TABLE "public"."api_rate_limits" TO "anon";
GRANT ALL ON TABLE "public"."api_rate_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."api_rate_limits" TO "service_role";



GRANT ALL ON TABLE "public"."app_admins" TO "anon";
GRANT ALL ON TABLE "public"."app_admins" TO "authenticated";
GRANT ALL ON TABLE "public"."app_admins" TO "service_role";



GRANT ALL ON TABLE "public"."app_feedback" TO "anon";
GRANT ALL ON TABLE "public"."app_feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."app_feedback" TO "service_role";



GRANT ALL ON TABLE "public"."beer_prices" TO "anon";
GRANT ALL ON TABLE "public"."beer_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."beer_prices" TO "service_role";



GRANT ALL ON TABLE "public"."beverage_barcode_submissions" TO "anon";
GRANT ALL ON TABLE "public"."beverage_barcode_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."beverage_barcode_submissions" TO "service_role";



GRANT ALL ON TABLE "public"."beverage_barcodes" TO "anon";
GRANT ALL ON TABLE "public"."beverage_barcodes" TO "authenticated";
GRANT ALL ON TABLE "public"."beverage_barcodes" TO "service_role";



GRANT ALL ON TABLE "public"."blocks" TO "anon";
GRANT ALL ON TABLE "public"."blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."blocks" TO "service_role";



GRANT ALL ON TABLE "public"."business_boosts" TO "anon";
GRANT ALL ON TABLE "public"."business_boosts" TO "authenticated";
GRANT ALL ON TABLE "public"."business_boosts" TO "service_role";



GRANT ALL ON TABLE "public"."business_card_deliveries" TO "anon";
GRANT ALL ON TABLE "public"."business_card_deliveries" TO "authenticated";
GRANT ALL ON TABLE "public"."business_card_deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."business_cards" TO "anon";
GRANT ALL ON TABLE "public"."business_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."business_cards" TO "service_role";



GRANT ALL ON TABLE "public"."business_events" TO "anon";
GRANT ALL ON TABLE "public"."business_events" TO "authenticated";
GRANT ALL ON TABLE "public"."business_events" TO "service_role";



GRANT ALL ON TABLE "public"."business_follows" TO "anon";
GRANT ALL ON TABLE "public"."business_follows" TO "authenticated";
GRANT ALL ON TABLE "public"."business_follows" TO "service_role";



GRANT ALL ON TABLE "public"."business_limits" TO "anon";
GRANT ALL ON TABLE "public"."business_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."business_limits" TO "service_role";



GRANT ALL ON TABLE "public"."business_orders" TO "anon";
GRANT ALL ON TABLE "public"."business_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."business_orders" TO "service_role";



GRANT ALL ON TABLE "public"."business_post_comments" TO "anon";
GRANT ALL ON TABLE "public"."business_post_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."business_post_comments" TO "service_role";



GRANT ALL ON TABLE "public"."business_post_likes" TO "anon";
GRANT ALL ON TABLE "public"."business_post_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."business_post_likes" TO "service_role";



GRANT ALL ON TABLE "public"."business_posts" TO "anon";
GRANT ALL ON TABLE "public"."business_posts" TO "authenticated";
GRANT ALL ON TABLE "public"."business_posts" TO "service_role";



GRANT ALL ON TABLE "public"."business_push_receipts" TO "anon";
GRANT ALL ON TABLE "public"."business_push_receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."business_push_receipts" TO "service_role";



GRANT ALL ON TABLE "public"."business_pushes" TO "anon";
GRANT ALL ON TABLE "public"."business_pushes" TO "authenticated";
GRANT ALL ON TABLE "public"."business_pushes" TO "service_role";



GRANT ALL ON TABLE "public"."business_subscription_log" TO "anon";
GRANT ALL ON TABLE "public"."business_subscription_log" TO "authenticated";
GRANT ALL ON TABLE "public"."business_subscription_log" TO "service_role";



GRANT ALL ON TABLE "public"."campaign_stats" TO "anon";
GRANT ALL ON TABLE "public"."campaign_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."campaign_stats" TO "service_role";



GRANT ALL ON TABLE "public"."contact_keys" TO "anon";
GRANT ALL ON TABLE "public"."contact_keys" TO "authenticated";
GRANT ALL ON TABLE "public"."contact_keys" TO "service_role";



GRANT ALL ON TABLE "public"."device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."dm_messages" TO "anon";
GRANT ALL ON TABLE "public"."dm_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."dm_messages" TO "service_role";



GRANT ALL ON TABLE "public"."event_members" TO "anon";
GRANT ALL ON TABLE "public"."event_members" TO "authenticated";
GRANT ALL ON TABLE "public"."event_members" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."friendships" TO "anon";
GRANT ALL ON TABLE "public"."friendships" TO "authenticated";
GRANT ALL ON TABLE "public"."friendships" TO "service_role";



GRANT ALL ON TABLE "public"."game_rounds" TO "anon";
GRANT ALL ON TABLE "public"."game_rounds" TO "authenticated";
GRANT ALL ON TABLE "public"."game_rounds" TO "service_role";



GRANT ALL ON TABLE "public"."invites" TO "anon";
GRANT ALL ON TABLE "public"."invites" TO "authenticated";
GRANT ALL ON TABLE "public"."invites" TO "service_role";



GRANT ALL ON TABLE "public"."list_guest_flags" TO "anon";
GRANT ALL ON TABLE "public"."list_guest_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."list_guest_flags" TO "service_role";



GRANT ALL ON TABLE "public"."list_requests" TO "anon";
GRANT ALL ON TABLE "public"."list_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."list_requests" TO "service_role";



GRANT ALL ON TABLE "public"."live_presence" TO "anon";
GRANT ALL ON TABLE "public"."live_presence" TO "authenticated";
GRANT ALL ON TABLE "public"."live_presence" TO "service_role";



GRANT ALL ON TABLE "public"."live_stories" TO "anon";
GRANT ALL ON TABLE "public"."live_stories" TO "authenticated";
GRANT ALL ON TABLE "public"."live_stories" TO "service_role";



GRANT ALL ON TABLE "public"."post_comments" TO "anon";
GRANT ALL ON TABLE "public"."post_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."post_comments" TO "service_role";



GRANT ALL ON TABLE "public"."post_likes" TO "anon";
GRANT ALL ON TABLE "public"."post_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."post_likes" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."reports" TO "anon";
GRANT ALL ON TABLE "public"."reports" TO "authenticated";
GRANT ALL ON TABLE "public"."reports" TO "service_role";



GRANT ALL ON TABLE "public"."session_drinks" TO "anon";
GRANT ALL ON TABLE "public"."session_drinks" TO "authenticated";
GRANT ALL ON TABLE "public"."session_drinks" TO "service_role";



GRANT ALL ON TABLE "public"."session_members" TO "anon";
GRANT ALL ON TABLE "public"."session_members" TO "authenticated";
GRANT ALL ON TABLE "public"."session_members" TO "service_role";



GRANT ALL ON TABLE "public"."session_snaps" TO "anon";
GRANT ALL ON TABLE "public"."session_snaps" TO "authenticated";
GRANT ALL ON TABLE "public"."session_snaps" TO "service_role";



GRANT ALL ON TABLE "public"."session_stops" TO "anon";
GRANT ALL ON TABLE "public"."session_stops" TO "authenticated";
GRANT ALL ON TABLE "public"."session_stops" TO "service_role";



GRANT ALL ON TABLE "public"."sessions" TO "anon";
GRANT ALL ON TABLE "public"."sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."sessions" TO "service_role";



GRANT ALL ON TABLE "public"."story_views" TO "anon";
GRANT ALL ON TABLE "public"."story_views" TO "authenticated";
GRANT ALL ON TABLE "public"."story_views" TO "service_role";



GRANT ALL ON TABLE "public"."venue_canonical" TO "anon";
GRANT ALL ON TABLE "public"."venue_canonical" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_canonical" TO "service_role";



GRANT ALL ON TABLE "public"."venue_offers" TO "anon";
GRANT ALL ON TABLE "public"."venue_offers" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_offers" TO "service_role";



GRANT ALL ON TABLE "public"."venue_push_log" TO "anon";
GRANT ALL ON TABLE "public"."venue_push_log" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_push_log" TO "service_role";



GRANT ALL ON TABLE "public"."venue_requests" TO "anon";
GRANT ALL ON TABLE "public"."venue_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_requests" TO "service_role";



GRANT ALL ON TABLE "public"."venue_specials" TO "anon";
GRANT ALL ON TABLE "public"."venue_specials" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_specials" TO "service_role";



GRANT ALL ON TABLE "public"."venue_sun" TO "anon";
GRANT ALL ON TABLE "public"."venue_sun" TO "authenticated";
GRANT ALL ON TABLE "public"."venue_sun" TO "service_role";



GRANT ALL ON TABLE "public"."venue_sun_facade_reports" TO "service_role";



GRANT ALL ON TABLE "public"."venues" TO "anon";
GRANT ALL ON TABLE "public"."venues" TO "authenticated";
GRANT ALL ON TABLE "public"."venues" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







