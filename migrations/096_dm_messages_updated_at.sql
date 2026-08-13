-- 096 — incremental sync for the DM poll (the app's #1 egress consumer).
--
-- DMService polled every 20 s and re-downloaded its ENTIRE window — the last
-- 500 messages, all columns — whether or not anything changed. At today's
-- volume that's ~1 MB per user-hour of app time; the cost scales as
-- (messages × polls × users), which is exactly the curve that filled the
-- egress chart in July for photos.
--
-- Same remedy as venues got in 088: a trigger-maintained updated_at and a
-- client cursor. A created_at cursor would NOT be enough here — read
-- receipts mutate rows in place (read_at), and those updates must reach the
-- other phone or messages never show as read.
--
-- Deletions aren't tracked; DMs have no delete path today. If one is added,
-- it must be a soft delete (deleted_at) so the cursor can carry it.

alter table dm_messages
  add column if not exists updated_at timestamptz not null default now();

-- Backfill: the last mutation we know of is the read receipt, else creation.
update dm_messages set updated_at = greatest(created_at, coalesce(read_at, created_at));

drop trigger if exists trg_dm_messages_touch_updated_at on dm_messages;
create trigger trg_dm_messages_touch_updated_at
  before update on dm_messages
  for each row execute function public.touch_updated_at();

-- The poll filters on (participant, updated_at >). Participant columns are
-- already indexed; updated_at needs one so the idle poll is an index-only
-- glance rather than a scan.
create index if not exists idx_dm_messages_updated_at on dm_messages (updated_at);

comment on column dm_messages.updated_at is
  'Set by trigger on every update; DMService''s incremental poll cursor (096). Deletions are not tracked — DMs have no delete path.';
