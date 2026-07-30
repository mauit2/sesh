-- 073_venue_canonical.sql — hide duplicate venues without deleting anything.
--
-- SYMPTOM: "the locations of some of the bars are inaccurate, for example
-- Handelspuben". The cause was not a bad coordinate transform — it was five
-- redundant venue rows, one pair of which disagreed about where the place is:
--
--   Handelspuben      x2, 645 m apart, both addressed "Vasagatan 1". Geocoding
--                     that address gives 57.69735,11.96146 — 96 m from the
--                     MapKit-resolved row and ~1 km from the curated one, so
--                     the curated row's coordinate was simply wrong.
--   John Scott's Pub  x2 at an identical coordinate.
--   Moon Thai Kitchen x3 at an identical coordinate.
--   Tacos & Tequila   x2 at an identical coordinate.
--
-- The map drew all of them, so a venue could appear in the wrong spot, and pin
-- labels collided because some venues were drawn two or three times.
--
-- DELIBERATELY NOT MERGED: Port Du Soleil's two rows are 1050 m apart with
-- DIFFERENT addresses (Nya allén 11 / Packhusplatsen 11) and different Apple
-- Maps ids — two real locations of the same name. Hence the key below is "same
-- name AND (within 150 m OR identical street address)": the address arm catches
-- Handelspuben, the distance arm catches same-spot copies, and neither
-- collapses a genuine second location.
--
-- This resolves each venue to a CANONICAL row and has the read paths ignore the
-- rest. Nothing is deleted, so it is reversible by re-running the refresh. The
-- physical merge is parked, unapplied, in migrations/pending/.

create table if not exists venue_canonical (
  venue_id     uuid primary key references venues(id) on delete cascade,
  canonical_id uuid not null references venues(id) on delete cascade,
  reason       text,
  refreshed_at timestamptz not null default now()
);

alter table venue_canonical enable row level security;

drop policy if exists venue_canonical_select on venue_canonical;
create policy venue_canonical_select on venue_canonical
  for select to authenticated using (true);

comment on table venue_canonical is
  'Maps each venue to the row that should represent it. venue_id = canonical_id means it IS canonical. Rebuild with refresh_venue_canonical().';

create or replace function refresh_venue_canonical() returns integer
language plpgsql security definer set search_path = public as $$
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
    -- Group key per row. Every duplicate set here is mutually connected, so the
    -- smallest id among {self, neighbours} identifies the component.
    -- min() has no uuid overload; uuid::text sorts identically to uuid.
    select s.a_id as id,
           least(s.a_id::text,
                 (select min(e.b_id::text) from edges e where e.a_id = s.a_id))::uuid as g
    from (select distinct a_id from edges) s
  ),
  survivor as (
    -- MapKit-resolved first (its coordinate came from Apple Maps rather than a
    -- hand-typed seed), then the oldest.
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
$$;

revoke all on function refresh_venue_canonical() from public, anon, authenticated;

-- Read paths return only canonical venues.
create or replace function venue_sun_map(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000
) returns table (
  venue_id uuid, name text, lat double precision, lon double precision,
  horizon smallint[], confidence real
) language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.lat, v.lon, s.horizon, s.confidence
  from venues v
  join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
    and coalesce(c.reason, 'unique') <> 'duplicate';
$$;

create or replace function venues_missing_sun(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000,
  p_limit integer default 12
) returns table (venue_id uuid, lat double precision, lon double precision)
language sql stable security definer set search_path = public as $$
  select v.id, v.lat, v.lon
  from venues v
  left join venue_sun s on s.venue_id = v.id
  left join venue_canonical c on c.venue_id = v.id
  where s.venue_id is null
    and coalesce(c.reason, 'unique') <> 'duplicate'
    and haversine_m(p_lat, p_lon, v.lat, v.lon) <= p_radius_m
  order by haversine_m(p_lat, p_lon, v.lat, v.lon)
  limit p_limit;
$$;

-- Populate it. Returns the number of rows now hidden as duplicates (5 at the
-- time of writing).
select refresh_venue_canonical();

notify pgrst, 'reload schema';
