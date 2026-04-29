-- Phase 1 of the venue scaling story: let users check into ANY bar via
-- Apple Maps without giving them a path to forge specials.
--
-- Three trust tiers, encoded in `venues.source`:
--   curated  — we vetted it. Only curated rows may have venue_specials.
--   mapkit   — created on-the-fly from MKLocalSearch when a user checks in.
--             Geographically real (Apple's POI database), but no specials.
--   user     — reserved for a future "add a place we missed" flow. Same
--             rules as mapkit for now.
--
-- A trigger enforces the curated-only rule on venue_specials so the
-- moderation guarantee can't be bypassed by flipping `source` later.
--
-- `external_id` is MKMapItem.identifier.rawValue (iOS 18+) for mapkit rows,
-- or any stable provider id for future sources. We dedupe on it via a
-- partial unique index — null external_ids (curated rows) are exempt.

alter table venues
  add column if not exists source       text not null default 'curated',
  add column if not exists external_id  text;

-- Constrain source to known tiers. Done as a separate statement so
-- re-running the migration doesn't fail on an existing constraint.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'venues_source_check'
  ) then
    alter table venues
      add constraint venues_source_check
      check (source in ('curated', 'mapkit', 'user'));
  end if;
end$$;

-- One row per (source, external_id). Curated rows have null external_id
-- and are excluded from the uniqueness check.
create unique index if not exists venues_source_external_idx
  on venues (source, external_id)
  where external_id is not null;

-- ---------------------------------------------------------------------------
-- Trigger: specials live only on curated venues. Looking up the parent
-- venue's source on every insert is cheap (PK lookup) and keeps the
-- check authoritative even if app code forgets.
-- ---------------------------------------------------------------------------

create or replace function venue_specials_curated_only()
returns trigger
language plpgsql
as $$
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

drop trigger if exists venue_specials_curated_only_trg on venue_specials;
create trigger venue_specials_curated_only_trg
  before insert or update on venue_specials
  for each row execute function venue_specials_curated_only();

-- ---------------------------------------------------------------------------
-- RLS: authenticated users may insert non-curated venues only.
-- Reads remain open per the existing policy. Curated rows continue to be
-- inserted via the service role (migrations / admin tooling).
-- ---------------------------------------------------------------------------

alter table venues enable row level security;

-- Read access: keep venues globally readable. Drop+recreate so the
-- policy shape stays canonical even if an earlier ad-hoc one exists.
drop policy if exists venues_read_all on venues;
create policy venues_read_all
  on venues for select
  using (true);

drop policy if exists venues_insert_non_curated on venues;
create policy venues_insert_non_curated
  on venues for insert
  to authenticated
  with check (
    auth.uid() is not null
    and source in ('mapkit', 'user')
  );

-- Specials stay read-only to clients; the curated-only trigger plus
-- service-role-only writes mean no client policy is needed for inserts.
alter table venue_specials enable row level security;
drop policy if exists venue_specials_read_all on venue_specials;
create policy venue_specials_read_all
  on venue_specials for select
  using (true);
