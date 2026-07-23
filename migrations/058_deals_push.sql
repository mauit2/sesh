-- 058_deals_push.sql
--
--  Step 5: opt-in "deals from nearby bars" push.
--   • profiles.deals_push_opt_in — default OFF; the user turns it on.
--   • send_venue_push(offer, title, body) — admin-only fan-out to opted-in
--     users, reusing private.notify_push (migration 028). Guardrails:
--       – weekly cap: at most 3 sends per venue per rolling 7 days.
--       – quiet hours: blocked 04:00–10:00 Europe/Stockholm (dead hours). A
--         nightlife app WANTS evening/late pushes, so only pre-dawn is muted.
--   • venue_push_log — one row per send (cap enforcement + a record to show
--     bars how many people a push reached).
--
--  Targeting is "all opted-in users" for now; per-city / checked-in geo
--  targeting is a Phase B refinement (we don't store live user locations).

alter table profiles add column if not exists deals_push_opt_in boolean not null default false;

-- Caller flips their own opt-in. SECURITY DEFINER so it works regardless of
-- how tight the profiles update policy is.
create or replace function public.set_deals_push_opt_in(p_on boolean)
returns void language sql security definer set search_path = public as $$
  update profiles set deals_push_opt_in = coalesce(p_on, false) where id = auth.uid();
$$;
grant execute on function public.set_deals_push_opt_in(boolean) to authenticated, service_role;

create table if not exists venue_push_log (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  offer_id uuid references venue_offers(id) on delete set null,
  sent_by  uuid references profiles(id),
  title    text not null,
  body     text not null,
  recipient_count int not null default 0,
  created_at timestamptz not null default now()
);
alter table venue_push_log enable row level security;
drop policy if exists venue_push_log_admin_select on venue_push_log;
create policy venue_push_log_admin_select on venue_push_log
  for select to authenticated
  using (exists (select 1 from app_admins where user_id = auth.uid()));

-- Admin fan-out. Returns how many opted-in users were reached.
create or replace function public.send_venue_push(
  p_offer_id uuid, p_title text, p_body text
) returns int
language plpgsql security definer set search_path = public, private as $$
declare v_venue uuid; v_recent int; v_hour int; v_count int := 0;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if coalesce(p_title,'') = '' or coalesce(p_body,'') = '' then raise exception 'empty'; end if;

  select venue_id into v_venue from venue_offers where id = p_offer_id;
  if v_venue is null then raise exception 'no_offer'; end if;

  -- Weekly cap: 3 sends per venue per rolling 7 days.
  select count(*) into v_recent from venue_push_log
   where venue_id = v_venue and created_at > now() - interval '7 days';
  if v_recent >= 3 then raise exception 'weekly_cap'; end if;

  -- Quiet hours: mute pre-dawn only (04:00–10:00 local).
  v_hour := extract(hour from (now() at time zone 'Europe/Stockholm'))::int;
  if v_hour >= 4 and v_hour < 10 then raise exception 'quiet_hours'; end if;

  -- Fan out to every opted-in user; notify_push swallows per-user failures.
  perform private.notify_push(p.id, p_title, p_body,
            jsonb_build_object('type','deal','venue_id', v_venue, 'offer_id', p_offer_id))
     from profiles p where p.deals_push_opt_in = true;

  select count(*) into v_count from profiles where deals_push_opt_in = true;

  insert into venue_push_log (venue_id, offer_id, sent_by, title, body, recipient_count)
  values (v_venue, p_offer_id, auth.uid(), p_title, p_body, v_count);
  return v_count;
end $$;
grant execute on function public.send_venue_push(uuid, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
