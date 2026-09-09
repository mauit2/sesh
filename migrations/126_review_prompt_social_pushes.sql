-- 126: the review prompt, the rest of the social pushes, and a Friday nudge.
--
--  • Review prompt state lives on profiles so a reinstall or second phone
--    never asks someone who already answered. app_feedback holds the
--    "not yet" answers — owner-readable only, never sent to Apple.
--  • Pushes that were missing: a friend going live, a bar you follow
--    posting, a bar you follow dropping a deal. Stories and timeline posts
--    already push (040). Per-bar mute: business_follows.notify, flipped by
--    the bell on the bar's profile. A bar cannot reach the same follower
--    more than once every 2 hours.
--  • Friday 16:00 Stockholm: one push a week, opt-out, worded to keep
--    track — never to drink.
--
-- Applied 2026-09-09 as review_prompt_social_pushes.

-- ── Review prompt ────────────────────────────────────────────────────────────
alter table profiles add column if not exists review_asked_at timestamptz;
alter table profiles add column if not exists review_done_at  timestamptz;

create or replace function public.review_prompt_state()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('asked_at', review_asked_at, 'done_at', review_done_at)
    from profiles where id = auth.uid();
$$;
grant execute on function public.review_prompt_state() to authenticated;

-- Every ask stamps asked_at; "Love it" also stamps done_at, after which the
-- prompt never comes back on any device.
create or replace function public.review_prompt_touch(p_done boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update profiles
     set review_asked_at = now(),
         review_done_at  = case when coalesce(p_done, false) then coalesce(review_done_at, now()) else review_done_at end
   where id = auth.uid();
  return public.review_prompt_state();
end $$;
grant execute on function public.review_prompt_touch(boolean) to authenticated;

create table if not exists app_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  message text not null check (length(message) between 1 and 2000),
  build text,
  created_at timestamptz not null default now()
);
alter table app_feedback enable row level security;
-- No user-facing policies on purpose: writes go through the RPC, reads
-- through the admin RPC. Nobody browses this table directly.

create or replace function public.app_feedback_add(p_message text, p_build text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if coalesce(trim(p_message), '') = '' then raise exception 'empty'; end if;
  insert into app_feedback (user_id, message, build) values (auth.uid(), left(trim(p_message), 2000), left(p_build, 40));
end $$;
grant execute on function public.app_feedback_add(text, text) to authenticated;

create or replace function public.admin_app_feedback()
returns table (id uuid, user_id uuid, name text, username text, message text, build text, created_at timestamptz)
language sql security definer set search_path = public, private as $$
  select f.id, f.user_id, p.name, p.username, f.message, f.build, f.created_at
    from app_feedback f join profiles p on p.id = f.user_id
   where private.is_app_admin()
   order by f.created_at desc
   limit 300;
$$;
grant execute on function public.admin_app_feedback() to authenticated;

-- ── Per-bar mute ─────────────────────────────────────────────────────────────
alter table business_follows add column if not exists notify boolean not null default true;
alter table business_follows add column if not exists last_notified_at timestamptz;

create or replace function public.set_business_follow_notify(p_business uuid, p_on boolean)
returns void language sql security definer set search_path = public as $$
  update business_follows set notify = coalesce(p_on, true)
   where user_id = auth.uid() and business_id = p_business;
$$;
grant execute on function public.set_business_follow_notify(uuid, boolean) to authenticated;

-- Fan a push out to a bar's followers who still want them. The owner of the
-- bar is never told about their own post.
create or replace function private.notify_business_followers(
  p_business uuid, p_title text, p_body text, p_data jsonb)
returns integer language plpgsql security definer set search_path = public, private as $$
declare f record; v_owner uuid; v_n integer := 0;
begin
  select owner_id into v_owner from businesses where id = p_business;
  for f in
    select user_id from business_follows
     where business_id = p_business and notify
       and user_id is distinct from v_owner
       and (last_notified_at is null or last_notified_at < now() - interval '2 hours')
  loop
    perform private.notify_push(f.user_id, p_title, p_body, p_data);
    update business_follows set last_notified_at = now()
     where user_id = f.user_id and business_id = p_business;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- A bar you follow posted.
create or replace function on_business_post_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_body text;
begin
  select name into v_name from businesses where id = NEW.business_id;
  v_body := coalesce(nullif(left(trim(NEW.caption), 90), ''), 'Something new from ' || v_name || '.');
  perform private.notify_business_followers(
    NEW.business_id, v_name || ' posted', v_body,
    jsonb_build_object('type', 'business_post', 'business_id', NEW.business_id, 'post_id', NEW.id));
  return NEW;
end $$;
drop trigger if exists trg_business_post_notify on business_posts;
create trigger trg_business_post_notify
  after insert on business_posts
  for each row execute function on_business_post_notify();

-- A bar you follow dropped a deal.
create or replace function on_business_offer_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
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
drop trigger if exists trg_business_offer_notify on venue_offers;
create trigger trg_business_offer_notify
  after insert on venue_offers
  for each row when (NEW.business_id is not null) execute function on_business_offer_notify();

-- A friend went live. The presence row is upserted on every pulse, so an
-- AFTER INSERT fires once per night: ending deletes the row.
create or replace function on_live_presence_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
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
drop trigger if exists trg_live_presence_notify on live_presence;
create trigger trg_live_presence_notify
  after insert on live_presence
  for each row execute function on_live_presence_notify();

-- ── The Friday nudge ─────────────────────────────────────────────────────────
alter table profiles add column if not exists weekend_push_opt_in boolean not null default true;

create or replace function public.set_weekend_push_opt_in(p_on boolean)
returns void language sql security definer set search_path = public as $$
  update profiles set weekend_push_opt_in = coalesce(p_on, true) where id = auth.uid();
$$;
grant execute on function public.set_weekend_push_opt_in(boolean) to authenticated;

create table if not exists private.weekend_push_log (
  week_start date primary key,
  recipient_count integer not null default 0,
  sent_at timestamptz not null default now()
);

-- Runs hourly on Fridays; only the 16:00 Stockholm tick does anything, and
-- only once per week. Copy rotates so it never reads as the same canned
-- line, and none of it tells anyone to drink.
create or replace function private.run_weekend_push()
returns integer language plpgsql security definer set search_path = public, private as $$
declare v_local timestamp := now() at time zone 'Europe/Stockholm';
        v_week date; v_n integer := 0; v_title text; v_body text; r record;
begin
  if extract(dow from v_local) <> 5 or extract(hour from v_local) <> 16 then return 0; end if;
  v_week := date_trunc('week', v_local)::date;
  if exists (select 1 from private.weekend_push_log where week_start = v_week) then return 0; end if;
  insert into private.weekend_push_log (week_start) values (v_week);

  case extract(week from v_local)::int % 3
    when 0 then v_title := 'Weekend, then.';
                v_body  := 'If you''re heading out, keep track of the night in one place. Drinks, stops, who''s live. And a way home.';
    when 1 then v_title := 'Friday''s here';
                v_body  := 'Whatever tonight looks like, Sejdel keeps the tab so you don''t have to. Water between rounds, taxi after.';
    else        v_title := 'The weekend''s on';
                v_body  := 'See who''s out, keep count, get home safe. That''s the whole point of it.';
  end case;

  for r in
    select p.id from profiles p
     where p.weekend_push_opt_in and p.business_id is null
       and exists (select 1 from device_tokens t where t.user_id = p.id)
  loop
    perform private.notify_push(r.id, v_title, v_body, jsonb_build_object('type', 'weekend'));
    v_n := v_n + 1;
  end loop;
  update private.weekend_push_log set recipient_count = v_n where week_start = v_week;
  return v_n;
end $$;

select cron.schedule('weekend-push', '0 * * * 5', $$select private.run_weekend_push()$$);
