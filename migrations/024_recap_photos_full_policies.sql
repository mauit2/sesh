-- 024_recap_photos_full_policies.sql
--
-- Final recap-photos storage policies. Root cause of the upload 400s: the app
-- uploads with upsert:true, so Storage runs INSERT ... ON CONFLICT DO UPDATE,
-- which RLS rejects unless an UPDATE policy also exists. The earlier sets
-- (020/021/023) only had insert (+delete), so the upsert was denied as a
-- "new row violates row-level security policy" error.
--
-- This mirrors the working `avatars` bucket exactly: full insert/update/
-- select/delete policies scoped to role public, each gated by
-- auth.uid() = first-folder so a user can only write to their own folder.
-- Supersedes the recap-photos policies in 020/021/023.

drop policy if exists "recap photos: insert own" on storage.objects;
drop policy if exists "recap photos: delete own" on storage.objects;
drop policy if exists "recap photos: update own" on storage.objects;
drop policy if exists "recap photos: select own" on storage.objects;

create policy "recap photos: insert own"
  on storage.objects for insert
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "recap photos: update own"
  on storage.objects for update
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "recap photos: select own"
  on storage.objects for select
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "recap photos: delete own"
  on storage.objects for delete
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);
