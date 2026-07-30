-- 078_venue_sun_override.sql — let local knowledge beat the model.
--
-- Building footprints cannot say which SIDE of a building a terrace is on, and
-- that is the whole ballgame for shade. Tacos & Tequila is the worked example:
-- it is crammed into a corner of an inner courtyard and gets no direct sun, but
-- the model evaluates the sunniest facade of its block and reports ten hours.
-- Three different heuristics were tried (nearest facade → zero sun, sunniest
-- facade → 10h15, median) and each is wrong for some venue, because the missing
-- information simply isn't in the data. So a human has to be able to win.
--
-- Stored in a SEPARATE column from the computed horizon on purpose: the
-- sun-horizon function rewrites `horizon` on every recompute, and an override
-- must survive that. Read paths prefer it via coalesce and report `is_override`
-- so the UI can label it "SET BY HAND" rather than passing local knowledge off
-- as modelled.

alter table venue_sun add column if not exists override_horizon smallint[];
alter table venue_sun add column if not exists override_note text;
alter table venue_sun add column if not exists override_at timestamptz;

alter table venue_sun drop constraint if exists venue_sun_override_bins;
alter table venue_sun add constraint venue_sun_override_bins
  check (override_horizon is null or array_length(override_horizon, 1) = 72);

comment on column venue_sun.override_horizon is
  'Hand-set horizon that wins over the computed one. Survives recomputes. Null = trust the model.';

create or replace function admin_set_venue_sun(
  p_venue uuid,
  p_mode  text,          -- 'no_sun' | 'open_sky' | 'clear'
  p_note  text default null
) returns void
language plpgsql security definer set search_path = public as $$
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
    -- reads as shade all day, at any latitude and season.
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

grant execute on function admin_set_venue_sun(uuid, text, text) to authenticated;

-- Every read path prefers the override and reports that it did.
drop function if exists venue_sun_map(double precision, double precision, double precision, integer, smallint);
drop function if exists search_sun_venues(text, double precision, double precision, integer);
drop function if exists sun_venue(uuid);

create function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 80,
  p_min_prominence smallint default 60
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null)
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
    and coalesce(c.reason, 'unique') <> 'duplicate'
    and v.prominence >= p_min_prominence
  order by v.prominence desc, haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit greatest(1, least(p_limit, 400));
$$;

create function search_sun_venues(
  p_query text,
  p_lat double precision default null,
  p_lon double precision default null,
  p_limit integer default 20
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean, distance_m double precision
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null),
         case when p_lat is null then null
              else haversine_m(p_lat, p_lon, v.lat, v.lon) end
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

create function sun_venue(p_venue_id uuid)
returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real, kind text, prominence smallint,
  time_zone text, is_override boolean
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null)
  from venues v
  join venue_sun s on s.venue_id = v.id
  where v.id = p_venue_id;
$$;

grant execute on function venue_sun_map(double precision, double precision, double precision, integer, smallint) to authenticated;
grant execute on function search_sun_venues(text, double precision, double precision, integer) to authenticated;
grant execute on function sun_venue(uuid) to authenticated;

-- The first override: Tacos & Tequila's courtyard corner.
update venue_sun s
   set override_horizon = array_fill(899::smallint, array[72]),
       override_note = 'Innergården corner — no direct sun (local knowledge)',
       override_at = now()
from venues v
left join venue_canonical c on c.venue_id = v.id
where s.venue_id = v.id
  and lower(v.name) like '%tacos%'
  and coalesce(c.reason, 'unique') <> 'duplicate';

notify pgrst, 'reload schema';
