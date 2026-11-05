-- Thumbnails for squad schnaps and stories stopped being written after
-- 21 Jul 2026. The storage API's upsert ends in RETURNING *, which needs a
-- SELECT policy on storage.objects for the uploader, and an UPDATE policy
-- for the conflict path. recap-photos and event-covers have both and kept
-- their thumbnails; session-snaps and stories only had INSERT + DELETE, so
-- every thumbnail upload since then was refused ("new row violates
-- row-level security policy", HTTP 400) and every viewer first asked for a
-- thumbnail that does not exist. Reads were unaffected (public buckets),
-- which is why nobody noticed. Seen in the edge logs of the group sesh of
-- 24 Oct 2026.

-- session-snaps: members of the session may read the objects in its folder
-- and overwrite only what they uploaded themselves.
drop policy if exists session_snaps_storage_select on storage.objects;
create policy session_snaps_storage_select on storage.objects
  for select to authenticated
  using (bucket_id = 'session-snaps'
         and public.is_session_member(((storage.foldername(name))[1])::uuid));

drop policy if exists session_snaps_storage_update on storage.objects;
create policy session_snaps_storage_update on storage.objects
  for update to authenticated
  using (bucket_id = 'session-snaps' and owner_id = auth.uid()::text)
  with check (bucket_id = 'session-snaps'
              and public.is_session_member(((storage.foldername(name))[1])::uuid));

-- stories: own folder only.
drop policy if exists stories_storage_select on storage.objects;
create policy stories_storage_select on storage.objects
  for select to authenticated
  using (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists stories_storage_update on storage.objects;
create policy stories_storage_update on storage.objects
  for update to authenticated
  using (bucket_id = 'stories' and owner_id = auth.uid()::text)
  with check (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);
