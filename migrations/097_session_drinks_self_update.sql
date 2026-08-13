-- 097 — let users correct WHEN they drank something.
--
-- The pace prompt (LIVE mode) spreads a burst of back-to-back logs across
-- the window the user says they actually drank them in, which means
-- rewriting created_at on rows that already exist. session_drinks had
-- insert/select/delete policies but no UPDATE at all, so the group path
-- had no way to re-stamp.
--
-- Own rows only, both sides of the policy: you can restate your own
-- timeline, never a friend's — and an UPDATE can't re-home a row into
-- someone else's ledger because the WITH CHECK pins profile_id too.

create policy "drinks: self update"
  on session_drinks for update
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());
