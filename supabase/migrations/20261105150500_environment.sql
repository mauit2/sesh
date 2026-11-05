-- Runs after the baseline. The baseline is a dump of the public and
-- private schemas; three things production also has live elsewhere and are
-- recreated here so a fresh database (local, or a future project) matches:
--   1. the six storage buckets,
--   2. the upload policies on storage.objects (migrations 021/024/034/045/
--      053/112 in the frozen folder created them),
--   3. the pg_cron schedules, which are rows in cron.job, not schema.
-- Everything is idempotent: on production this is a no-op apart from
-- re-creating identical policies and re-registering identical jobs.

-- 1. Buckets ---------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',       'avatars',       true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('campaign-art',  'campaign-art',  true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('event-covers',  'event-covers',  true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('recap-photos',  'recap-photos',  true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('session-snaps', 'session-snaps', true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif']),
  ('stories',       'stories',       true, 15728640, array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do nothing;

-- 2. Policies on storage.objects --------------------------------------------
-- Avatars: each user owns the folder named after their id.
drop policy if exists "avatars_owner_write h0za56_0" on storage.objects;
create policy "avatars_owner_write h0za56_0" on storage.objects for insert to public
  with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
drop policy if exists "avatars_owner_write h0za56_1" on storage.objects;
create policy "avatars_owner_write h0za56_1" on storage.objects for update to public
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
drop policy if exists "avatars_owner_write h0za56_2" on storage.objects;
create policy "avatars_owner_write h0za56_2" on storage.objects for select to public
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
drop policy if exists "avatars_owner_write h0za56_3" on storage.objects;
create policy "avatars_owner_write h0za56_3" on storage.objects for delete to public
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

-- Campaign art: admins, and approved business owners under business/<id>/.
drop policy if exists "campaign_art_business_insert" on storage.objects;
create policy "campaign_art_business_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'campaign-art' and (storage.foldername(name))[1] = 'business'
    and exists (select 1 from public.businesses b
                 where b.owner_id = auth.uid() and b.status = 'approved'
                   and b.id::text = (storage.foldername(objects.name))[2]));
drop policy if exists "campaign_art_insert" on storage.objects;
create policy "campaign_art_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'campaign-art' and exists (select 1 from public.app_admins where user_id = auth.uid()));
drop policy if exists "campaign_art_update" on storage.objects;
create policy "campaign_art_update" on storage.objects for update to authenticated
  using (bucket_id = 'campaign-art' and exists (select 1 from public.app_admins where user_id = auth.uid()))
  with check (bucket_id = 'campaign-art' and exists (select 1 from public.app_admins where user_id = auth.uid()));

-- Event covers: the event's host writes under <event id>/.
drop policy if exists "event_covers_delete" on storage.objects;
create policy "event_covers_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'event-covers' and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid()));
drop policy if exists "event_covers_insert" on storage.objects;
create policy "event_covers_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'event-covers' and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid()));
drop policy if exists "event_covers_select" on storage.objects;
create policy "event_covers_select" on storage.objects for select to authenticated
  using (bucket_id = 'event-covers' and owner = auth.uid());
drop policy if exists "event_covers_update" on storage.objects;
create policy "event_covers_update" on storage.objects for update to authenticated
  using (bucket_id = 'event-covers' and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid()))
  with check (bucket_id = 'event-covers' and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid()));

-- Recap photos: own folder only.
drop policy if exists "recap photos: delete own" on storage.objects;
create policy "recap photos: delete own" on storage.objects for delete to public
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "recap photos: insert own" on storage.objects;
create policy "recap photos: insert own" on storage.objects for insert to public
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "recap photos: select own" on storage.objects;
create policy "recap photos: select own" on storage.objects for select to public
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "recap photos: update own" on storage.objects;
create policy "recap photos: update own" on storage.objects for update to public
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Squad snaps: members of the session write under <session id>/; the
-- uploader or the host deletes.
drop policy if exists "session_snaps_storage_delete" on storage.objects;
create policy "session_snaps_storage_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'session-snaps' and (owner_id = auth.uid()::text
    or exists (select 1 from public.sessions s
                where s.id::text = (storage.foldername(objects.name))[1] and s.host_id = auth.uid())));
drop policy if exists "session_snaps_storage_insert" on storage.objects;
create policy "session_snaps_storage_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'session-snaps' and public.is_session_member(((storage.foldername(name))[1])::uuid));

-- Stories: own folder; the uploader deletes.
drop policy if exists "stories_storage_delete" on storage.objects;
create policy "stories_storage_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'stories' and owner_id = auth.uid()::text);
drop policy if exists "stories_storage_insert" on storage.objects;
create policy "stories_storage_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);

-- 3. Scheduled jobs (cron.schedule by name replaces an existing job) -------
select cron.schedule('cleanup-session-snaps', '0 9 * * *',    $$select private.cleanup_snaps_http()$$);
select cron.schedule('event-live-lifecycle',  '* * * * *',    $$select public.run_event_live_lifecycle()$$);
select cron.schedule('business-pushes',       '* * * * *',    $$select private.run_business_pushes()$$);
select cron.schedule('business-presence',     '*/10 * * * *', $$select private.run_business_presence()$$);
select cron.schedule('weekend-push',          '0 * * * *',    $$select private.run_weekend_push()$$);
select cron.schedule('group-autoend',         '*/10 * * * *', $$select private.run_group_autoend()$$);
select cron.schedule('push-outbox',           '15 seconds',   $$select private.run_push_outbox()$$);
