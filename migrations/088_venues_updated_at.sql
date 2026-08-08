-- 088_venues_updated_at.sql — let the app sync only what changed.
--
-- WHY. Every app launch pulls the whole venues table (3 paged requests, ~194 KB
-- compressed) and repeats it every five minutes while the maps are open. At 2150
-- venues that is ~2.3 MB per active hour per user of PostgREST egress to re-send
-- data that almost never changes — 93% of the project's egress on a busy day.
-- With a change cursor the client fetches the full catalog once, then only rows
-- touched since, which is normally zero rows.
--
-- DELETES are deliberately NOT tracked. A tombstone table is the usual answer,
-- but venues are essentially never deleted (duplicates are hidden via
-- venue_canonical, not removed — see 073), so the client instead does a full
-- resync when its cache is older than a day. That bounds the staleness of a
-- deletion to 24 hours for a cost of one full pull per day.

alter table venues add column if not exists updated_at timestamptz not null default now();

-- Existing rows: created_at is the best available "last changed" stamp.
update venues set updated_at = coalesce(created_at, now())
 where updated_at is null or updated_at > now();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_venues_touch_updated_at on venues;
create trigger trg_venues_touch_updated_at
  before update on venues
  for each row execute function public.touch_updated_at();

-- The cursor query is `updated_at > $1`, so index it descending-friendly.
create index if not exists venues_updated_at_idx on venues (updated_at);

comment on column venues.updated_at is
  'Set by trigger on every update; the app''s incremental-sync cursor (see 088). Deletions are not tracked — the client full-resyncs daily.';

notify pgrst, 'reload schema';
