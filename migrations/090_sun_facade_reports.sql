-- 090_sun_facade_reports.sql — let users tell us which way the seats face.
--
-- WHY THIS AND NOT AN OVERRIDE. The horizon model can read building heights but
-- has no idea which side of a building the seating is on, so it guesses: the
-- facade most open toward the equator. That guess is OPTIMISTIC by construction
-- — it picks the sunniest side. Bar Etzy came out facing east (morning sun, dead
-- afternoon) purely on that basis.
--
-- The fix is not to override the model with a human's estimate of sun hours;
-- people are bad at that and it would rot as buildings change. It is to supply
-- the ONE fact the tiles cannot carry — the bearing the seating faces — and let
-- the same ray-casting run from that side. Geometry stays authoritative.
--
-- REPORTS ARE PER PERSON, aggregated. One row per (venue, profile), re-reportable,
-- and the agreed bearing is the CIRCULAR mean. A plain average is wrong for
-- bearings: 350 and 10 degrees average to 180 (due south) when the answer is due
-- north. Verified: naive avg -> 180, circular mean -> 0.

alter table venue_sun add column if not exists facade_bearing smallint;
alter table venue_sun add column if not exists facade_reports smallint not null default 0;

comment on column venue_sun.facade_bearing is
  'Compass bearing the seating faces, agreed from user reports. Fed to the sun-horizon function so it casts from THAT side instead of guessing the sunniest one.';

create table if not exists venue_sun_facade_reports (
  venue_id   uuid not null references venues(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  bearing    smallint not null check (bearing >= 0 and bearing < 360),
  created_at timestamptz not null default now(),
  primary key (venue_id, profile_id)
);

alter table venue_sun_facade_reports enable row level security;

-- No direct access: the agreed value lives on venue_sun, and raw reports are
-- per-person data. Writes go through the RPC only.
revoke all on table venue_sun_facade_reports from anon, authenticated;

create or replace function public.agreed_facade_bearing(p_venue uuid)
returns smallint
language sql
stable
set search_path to 'public'
as $$
  select case when count(*) = 0 then null else
    ((degrees(atan2(sum(sin(radians(bearing))), sum(cos(radians(bearing)))))::int % 360) + 360) % 360
  end::smallint
  from venue_sun_facade_reports where venue_id = p_venue;
$$;

create or replace function public.report_sun_facade(p_venue uuid, p_bearing smallint)
returns smallint
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid := auth.uid(); v_agreed smallint; v_n smallint;
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_bearing is null or p_bearing < 0 or p_bearing >= 360 then
    raise exception 'bad_bearing';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;

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
end;
$$;

grant execute on function public.report_sun_facade(uuid, smallint) to authenticated;
revoke all on function public.agreed_facade_bearing(uuid) from anon, authenticated;

notify pgrst, 'reload schema';
