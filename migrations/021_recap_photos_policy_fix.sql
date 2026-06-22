-- 021_recap_photos_policy_fix.sql
--
-- The recap-photos storage policies in 020 were scoped to role `authenticated`
-- and rejected uploads with HTTP 400. Mirror the proven `avatars` bucket
-- policies instead: scope to `public` (covers the storage request role
-- reliably) while the auth.uid() = first-folder check still restricts writes
-- to the owner (anonymous requests have a null auth.uid() and fail the check).

drop policy if exists "recap photos: insert own" on storage.objects;
create policy "recap photos: insert own"
  on storage.objects for insert
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "recap photos: delete own" on storage.objects;
create policy "recap photos: delete own"
  on storage.objects for delete
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);
