-- 059_deals_geo_targeting.sql
--
--  Deal pushes should only reach people NEAR the bar, not every opted-in user
--  in the country. We store a coarse, recent location per opted-in user (the
--  client rounds it to ~1 km and only sends it when opted in) and filter
--  send_venue_push to a 5 km radius of the venue.
--
--  (The app-open interstitial is geo-restricted client-side to the same
--  radius — no server change needed there.)

-- Great-circle distance in metres. Immutable so it can sit in a WHERE clause.
create or replace function public.haversine_m(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
) returns double precision language sql immutable parallel safe as $$
  select 6371000 * 2 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lon2 - lon1) / 2), 2)
  )));
$$;

alter table profiles
  add column if not exists deals_lat    double precision,
  add column if not exists deals_lon    double precision,
  add column if not exists deals_loc_at timestamptz;

-- Caller reports a coarse recent location (client rounds it). Only meaningful
-- once they've opted in — that's the audience send_venue_push targets.
create or replace function public.set_deals_location(p_lat double precision, p_lon double precision)
returns void language sql security definer set search_path = public as $$
  update profiles
     set deals_lat = p_lat, deals_lon = p_lon, deals_loc_at = now()
   where id = auth.uid();
$$;
grant execute on function public.set_deals_location(double precision, double precision) to authenticated, service_role;

-- Rebuild send_venue_push: fan out only to opted-in users with a recent
-- coarse location within 5 km of the bar. Weekly cap + quiet hours unchanged.
create or replace function public.send_venue_push(
  p_offer_id uuid, p_title text, p_body text
) returns int
language plpgsql security definer set search_path = public, private as $$
declare
  v_venue uuid; v_lat double precision; v_lon double precision;
  v_recent int; v_hour int; v_count int := 0;
  c_radius_m constant double precision := 5000;   -- "near the bar"
  c_fresh    constant interval := interval '30 days';
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  if coalesce(p_title,'') = '' or coalesce(p_body,'') = '' then raise exception 'empty'; end if;

  select venue_id into v_venue from venue_offers where id = p_offer_id;
  if v_venue is null then raise exception 'no_offer'; end if;
  select lat, lon into v_lat, v_lon from venues where id = v_venue;

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
grant execute on function public.send_venue_push(uuid, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
