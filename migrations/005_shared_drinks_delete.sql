-- Bug: a shared drink (a round) could only be removed by the person who
-- added it. Symptom in the app: the row would disappear briefly (optimistic
-- local removal) and then snap back on the next poll, because the DELETE
-- was rejected by RLS server-side.
--
-- Cause: the existing DELETE policy on session_drinks scopes deletes to
-- the row's owner (`profile_id = auth.uid()`). For a shared round that's
-- wrong — the row is owned by the person who tapped "+" but the round
-- belongs to the whole group, so any member should be able to undo it.
--
-- Fix: replace the DELETE policy with one that allows either:
--   1. the row's owner to delete it (unchanged for personal drinks), OR
--   2. any active member of the same session to delete it, but ONLY when
--      the row is marked `shared = true`.
--
-- The shared-only carve-out keeps personal drinks private — group members
-- still can't delete each other's non-shared drinks.

alter table session_drinks enable row level security;

-- Drop any prior delete policies so the new one is canonical regardless
-- of what the project started with. We try the common names; unknown
-- ones are no-ops.
drop policy if exists session_drinks_delete_own on session_drinks;
drop policy if exists session_drinks_delete on session_drinks;
drop policy if exists session_drinks_delete_member on session_drinks;
drop policy if exists "Users can delete their own session drinks" on session_drinks;
drop policy if exists "Enable delete for users based on profile_id" on session_drinks;

create policy session_drinks_delete_member
  on session_drinks for delete
  to authenticated
  using (
    -- Owner can always delete their own row.
    profile_id = auth.uid()
    or (
      -- Anyone else can delete it only if it's a shared round AND they
      -- are a member of the same session.
      shared = true
      and exists (
        select 1 from session_members sm
        where sm.session_id = session_drinks.session_id
          and sm.profile_id = auth.uid()
      )
    )
  );
