-- Bug: when a member tapped "Leave sesh", the rest of the group never
-- saw them disappear from the roster. Symptom: the leaver's row stayed
-- visible on every other phone for the lifetime of the session.
--
-- Two causes, fixed together:
--
-- 1. Client side (handled in content_view.swift): `leave()` had a
--    cousin-shares carve-out that skipped the DELETE entirely when the
--    user's other mode (plan↔live) also tracked this session. So if
--    they'd mirrored, leaving was a local-only no-op. That's been
--    flipped — DELETE now always runs, and the cousin scope gets
--    cleared in lockstep when it shares the session.
--
-- 2. Server side (this migration): the existing DELETE policy on
--    session_members may not exist, or may be scoped too tightly to
--    let a member remove their own row. We don't know the prior shape
--    for sure (no canonical migration in the repo), so this drops any
--    plausibly-named prior policies and installs a single canonical
--    one. Idempotent — safe to re-run.
--
-- Policy intent: a user can delete their own membership row, full stop.
-- Hosts don't need delete authority over other members' rows; ending
-- the session flips `sessions.active = false`, and every member's poll
-- detects the inactive flag and clears their local state.

alter table session_members enable row level security;

-- Drop any prior delete policies under common names so the new one is
-- canonical regardless of what the project started with. Unknown names
-- are no-ops via `if exists`.
drop policy if exists session_members_delete_own       on session_members;
drop policy if exists session_members_delete           on session_members;
drop policy if exists session_members_delete_self      on session_members;
drop policy if exists "Users can delete their own session_members" on session_members;
drop policy if exists "Enable delete for users based on profile_id" on session_members;

create policy session_members_delete_own
  on session_members for delete
  to authenticated
  using ( profile_id = auth.uid() );
