-- 034_group_snaps.sql
--
-- Group snaps: while a live group sesh runs, members can share their Night
-- Snaps photos with the group. Storage-conscious by design:
--   • clients upload aggressively compressed JPEGs (~1280px / q0.62,
--     roughly 150–250 KB each)
--   • snaps are EPHEMERAL — a daily job purges anything older than 48h
--     (storage objects + rows), so steady-state usage stays in the tens
--     of MB even with heavy use.
--
-- The purge runs via pg_cron → pg_net → the cleanup-snaps Edge Function,
-- authenticated with the same shared hook secret as send-push (the
-- function does the actual storage deletion with the service role, the
-- only reliable way to remove objects).

create table if not exists session_snaps (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references sessions(id) on delete cascade,
  profile_id   uuid not null references profiles(id) on delete cascade,
  stop_name    text,
  storage_path text not null,
  created_at   timestamptz not null default now()
);

create index if not exists session_snaps_session_idx on session_snaps (session_id);
create index if not exists session_snaps_created_idx on session_snaps (created_at);

alter table session_snaps enable row level security;

drop policy if exists session_snaps_member_select on session_snaps;
create policy session_snaps_member_select on session_snaps
  for select to authenticated using (is_session_member(session_id));
drop policy if exists session_snaps_self_insert on session_snaps;
create policy session_snaps_self_insert on session_snaps
  for insert to authenticated
  with check (profile_id = auth.uid() and is_session_member(session_id));
drop policy if exists session_snaps_self_delete on session_snaps;
create policy session_snaps_self_delete on session_snaps
  for delete to authenticated using (profile_id = auth.uid());

grant select, insert, delete on session_snaps to authenticated;

-- Public bucket (objects served by URL like avatars/recap-photos); path is
-- {session_id}/{uuid}.jpg so the insert policy can gate on membership.
insert into storage.buckets (id, name, public)
values ('session-snaps', 'session-snaps', true)
on conflict (id) do nothing;

drop policy if exists session_snaps_storage_insert on storage.objects;
create policy session_snaps_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'session-snaps'
    and is_session_member(((storage.foldername(name))[1])::uuid)
  );
drop policy if exists session_snaps_storage_delete on storage.objects;
create policy session_snaps_storage_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'session-snaps' and owner_id = auth.uid()::text);

-- ---------------------------------------------------------------------------
-- Expiry: daily purge of snaps older than 48h.
-- ---------------------------------------------------------------------------

create extension if not exists pg_cron;

create or replace function private.cleanup_snaps_http() returns void
language plpgsql security definer set search_path = public, private as $$
declare cfg private.push_config;
begin
  select * into cfg from private.push_config where id = 1;
  if cfg.function_url is null then return; end if;
  perform net.http_post(
    url     := replace(cfg.function_url, '/send-push', '/cleanup-snaps'),
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || cfg.secret),
    body    := '{}'::jsonb
  );
exception when others then
  return;
end $$;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'cleanup-session-snaps') then
    perform cron.schedule('cleanup-session-snaps', '0 9 * * *',
                          'select private.cleanup_snaps_http()');
  end if;
end $$;
