-- In-app invites: a host (or any session member) can send an invite
-- row that the recipient's app polls for and surfaces as a tappable
-- "Join the sesh" banner. No push notifications yet — the recipient
-- has to have the app open (or foreground it) to see the invite. Push
-- can be layered on later by reading from this same table.
--
-- Status machine: pending → accepted | declined | expired.
-- Only the recipient can flip pending → accepted/declined. `expired`
-- is reserved for a future cleanup job (e.g. invites older than 24h
-- that nobody acted on).
--
-- Dedupe key: one invite per (session, recipient). Upserts use
-- `on conflict do nothing` so re-sending to the same crew (e.g. the
-- host taps "send invite" twice while polling) doesn't create dupes.

create table if not exists invites (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references sessions(id) on delete cascade,
  sender_id     uuid not null references profiles(id) on delete cascade,
  recipient_id  uuid not null references profiles(id) on delete cascade,
  -- Snapshot the join code at send time. Sessions can in theory have
  -- their code regenerated later (not currently a flow, but cheap
  -- insurance) — the recipient should join the session that was
  -- *intended* at send time, not whatever the code points at now.
  join_code     text not null,
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,
  status        text not null default 'pending'
                check (status in ('pending', 'accepted', 'declined', 'expired')),
  unique (session_id, recipient_id)
);

-- Hot path index: "give me my pending invites, newest first". Partial
-- so the index stays tight (only pending rows matter — accepted /
-- declined / expired don't need to be in this lookup).
create index if not exists invites_recipient_pending_idx
  on invites (recipient_id, created_at desc) where status = 'pending';

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------

alter table invites enable row level security;

-- Read: either party can see the invite. Recipient needs it to render
-- their inbox; sender needs it to track who's responded (future UI).
drop policy if exists invites_select_own on invites;
create policy invites_select_own
  on invites for select
  to authenticated
  using ( recipient_id = auth.uid() or sender_id = auth.uid() );

-- Insert: you can only send invites as yourself, and only for
-- sessions you're actually a member of in some mode (in_plan or
-- in_live). Without this carve-out, anyone with a session id could
-- inject invites pointing at someone else's group.
drop policy if exists invites_insert_as_sender on invites;
create policy invites_insert_as_sender
  on invites for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from session_members sm
      where sm.session_id = invites.session_id
        and sm.profile_id = auth.uid()
        and (sm.in_plan or sm.in_live)
    )
  );

-- Update: the recipient can update their own invite (accept/decline).
-- We don't lock them to specific status transitions in RLS — that
-- check is cheap to do client-side and keeps the policy readable.
drop policy if exists invites_update_recipient on invites;
create policy invites_update_recipient
  on invites for update
  to authenticated
  using       ( recipient_id = auth.uid() )
  with check  ( recipient_id = auth.uid() );

-- Force PostgREST to reload the schema cache so the new table is
-- visible to clients without a server restart.
notify pgrst, 'reload schema';
