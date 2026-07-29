-- 070_venue_heat_and_qr.sql
--
-- "Where's it hot tonight" on the Nightline map, plus QR check-in — the two
-- halves of the same loop: bars get a visible reason to push check-ins, and a
-- QR on the table makes checking in one scan.
--
-- PRIVACY — the load-bearing decisions here:
--   * Counts are NEVER returned. The RPC emits a band (1 warming / 2 busy /
--     3 packed) so a venue can't be used to infer "how many people are at
--     this bar right now", let alone who.
--   * k-anonymity floor: a cluster is invisible until HEAT_MIN_PEOPLE
--     distinct people have checked in. Below that, one person's check-in
--     could be read off the map — which is exactly the stalking vector a
--     nightlife app must not ship. This is why the map can look empty in a
--     small city; that is the feature working, not a bug.
--   * Rolling window only (tonight), so heat is never a location history.
--   * Check-ins are deliberate, foreground actions and the aggregate is
--     anonymous, so this does not use the friends-map location toggle (which
--     governs showing YOU, personally, to friends).
--
-- session_stops has no venue_id — stops carry a name + coordinate — so heat
-- clusters on the bar NAME, with a coarse ~1 km grid only to keep same-named
-- chains apart. (Pure grid clustering split bars sitting near a grid line
-- into two under-threshold cells that never heated up.)

-- ---------- QR check-in ----------

-- Short, unguessable, stable per venue. Printed on the table tent.
alter table venues add column if not exists qr_token text unique;

create or replace function public.ensure_qr_token(p_venue uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  select qr_token into v_token from venues where id = p_venue;
  if v_token is not null then return v_token; end if;
  -- 10 chars of base32-ish alphabet, no look-alikes (0/O/1/I)
  loop
    v_token := (select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
                                         (random() * 31)::int + 1, 1), '')
                from generate_series(1, 10));
    exit when not exists (select 1 from venues where qr_token = v_token);
  end loop;
  update venues set qr_token = v_token where id = p_venue;
  return v_token;
end $$;
revoke all on function public.ensure_qr_token(uuid) from public;
grant execute on function public.ensure_qr_token(uuid) to authenticated;

-- Scanning resolves a token to the venue; the client then runs its normal
-- check-in path. Returns nothing for an unknown token (no enumeration hints).
create or replace function public.venue_for_qr(p_token text)
returns table (id uuid, name text, address text, city text,
               lat double precision, lon double precision)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.address, v.city, v.lat, v.lon
  from venues v
  where v.qr_token = upper(trim(p_token))
  limit 1;
$$;
grant execute on function public.venue_for_qr(text) to authenticated;

-- ---------- heat ----------

-- CAPACITY, learned not entered: a packed 40-cap bar is hotter than a
-- third-full 500-cap one, but asking bars to maintain capacity data is a
-- non-starter. So each bar is banded against ITS OWN typical night — the
-- median distinct check-ins over the trailing 28 days — which learns venue
-- size for free. That branch activates per-bar at 4+ nights of history;
-- until then (and always, as the other half of a GREATEST) the area-relative
-- bands apply: heat as share of everyone out around here tonight
-- (100-of-1000 downtown and 7-of-20 in a small town both read hot), with
-- small absolute floors so three friends at one bar can never mint a HOT in
-- a dead market. intensity stays relative to the busiest cluster
-- (leader = 1.0), quantized to 0.05 steps — smooth enough to size dots, too
-- coarse to reconstruct head-counts.
create or replace function public.venue_heat(
  p_lat double precision,
  p_lon double precision,
  p_radius_m double precision default 25000
)
returns table (name text, lat double precision, lon double precision,
               band int, intensity double precision)
language sql stable security definer set search_path = public as $$
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
grant execute on function public.venue_heat(double precision, double precision, double precision) to authenticated;

notify pgrst, 'reload schema';
