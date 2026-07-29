-- 069_birthdate_and_hardening.sql
--
-- Birthdate on profiles: the app stored a static age, which drifts a year
-- out of date every birthday. New sign-ups pick a birthdate (age derived);
-- existing users are prompted once in-app. `age` stays not-null for older
-- clients — it's recomputed whenever birthdate is set.
alter table profiles add column if not exists birthdate date;

-- Security-advisor cleanups ahead of App Store submission:

-- Pin search_path on the three flagged helper functions.
alter function public.widmark_bac(jsonb, double precision, text, timestamp with time zone) set search_path = public;
alter function public.haversine_m(double precision, double precision, double precision, double precision) set search_path = public;
alter function public.recap_display(jsonb, boolean) set search_path = public;

-- event-covers is a public bucket: object URLs don't need SELECT on
-- storage.objects, so the old bucket-wide policy let any client LIST every
-- file. Scope it to the uploader (SELECT is still needed for the owner
-- because cover upload is an upsert — ON CONFLICT ... RETURNING).
drop policy if exists event_covers_select on storage.objects;
create policy event_covers_select on storage.objects
  for select to authenticated
  using (bucket_id = 'event-covers' and owner = auth.uid());

-- Not fixable in SQL, done alongside this migration:
--  * Leaked-password protection (HaveIBeenPwned check) — Dashboard >
--    Authentication > Settings toggle.
--  * post_likes / post_comments keep RLS-with-no-policies deliberately:
--    all access is through SECURITY DEFINER RPCs (list_comments,
--    add_comment, delete_comment, my_post_activity), so deny-all direct
--    access is the intended posture, not an oversight.
