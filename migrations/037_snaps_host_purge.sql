-- 037_snaps_host_purge.sql
--
-- Squad schnaps don't outlive the sesh: once it ends, the daily cleanup
-- sweep (cleanup-snaps edge function) purges them — members get a window
-- to save schnaps into their journey / group recap first. These policies
-- additionally let the HOST delete any of the session's schnaps from the
-- client (not just their own), so in-app moderation is possible.

drop policy if exists session_snaps_self_delete on session_snaps;
create policy session_snaps_self_delete on session_snaps
  for delete to authenticated using (
    profile_id = auth.uid()
    or exists (
      select 1 from sessions s
      where s.id = session_snaps.session_id and s.host_id = auth.uid()
    )
  );

drop policy if exists session_snaps_storage_delete on storage.objects;
create policy session_snaps_storage_delete on storage.objects
  for delete to authenticated using (
    bucket_id = 'session-snaps'
    and (
      owner_id = auth.uid()::text
      or exists (
        select 1 from sessions s
        where s.id::text = (storage.foldername(name))[1]
          and s.host_id = auth.uid()
      )
    )
  );
