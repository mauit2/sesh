-- 089_venue_sun_by_ids.sql — fetch sun horizons for an explicit set of venues.
--
-- WHY, when venue_sun_map already exists. venue_sun_map answers "what's near
-- this coordinate", which is the wrong question for the Sun map. The app knows
-- locally which bars have beer prices and which of those are in view — that is
-- exactly the set the Beer map draws — and the only thing it lacks is their
-- horizons. Asking by id makes the Sun map's pins IDENTICAL to the Beer map's
-- by construction, instead of two independently-derived sets that drift.
--
-- It also removes a real bug. The geo fetch used a fixed 25 km radius around
-- wherever the map happened to be when Sun was warmed, and never followed a
-- pan, so panning away left the Sun map showing whatever it first loaded. On
-- the website the same fixed radius was worse than stale: after the Beer map
-- auto-fits to every pin, the centre lands near the centroid of all priced
-- venues — rural Ostergotland — which has ZERO priced bars within 25 km.
--
-- venue_sun_map is kept: search and the pinned-venue path still ask "what's
-- near here", which is the question it is right for.
--
-- The 400-row ceiling is a backstop; callers ask for a viewport's worth (~150).

create or replace function public.venue_sun_by_ids(p_ids uuid[])
returns table(venue_id uuid, name text, lat double precision, lon double precision,
              horizon smallint[], confidence real, kind text, prominence smallint,
              time_zone text, is_override boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select v.id, v.name, v.lat, v.lon,
         coalesce(s.override_horizon, s.horizon),
         s.confidence, v.kind, v.prominence, v.time_zone,
         (s.override_horizon is not null)
    from venues v
    join venue_sun s on s.venue_id = v.id
   where v.id = any(p_ids)
   limit 400;
$$;

grant execute on function public.venue_sun_by_ids(uuid[]) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
