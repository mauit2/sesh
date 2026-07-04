-- 036_live_stories.sql
--
-- Live stories for the Nightline TONIGHT strip: a photo a user posts to
-- their friends mid-night, stamped (optionally) with their at-the-moment
-- BAC, a caption, and their check-in / pre-game / between-bars label.
-- Stories are EPHEMERAL: reads filter to the last 24h, and the daily
-- cleanup job purges expired rows + storage objects.

create table if not exists live_stories (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references profiles(id) on delete cascade,
  storage_path text not null,
  caption      text,
  bac          double precision,   -- raw %-scale at post time; null = not attached
  stamp        text,               -- venue / pre-game / between-bars label; null = none
  created_at   timestamptz not null default now()
);

create index if not exists live_stories_profile_idx on live_stories (profile_id);
create index if not exists live_stories_created_idx on live_stories (created_at);

alter table live_stories enable row level security;

-- Fresh stories are visible to the author and their accepted friends.
drop policy if exists live_stories_friends_select on live_stories;
create policy live_stories_friends_select on live_stories
  for select to authenticated using (
    created_at > now() - interval '24 hours'
    and (
      profile_id = auth.uid()
      or exists (
        select 1 from friendships fr
        where fr.status = 'accepted'
          and ((fr.requester_id = auth.uid() and fr.addressee_id = live_stories.profile_id)
            or (fr.addressee_id = auth.uid() and fr.requester_id = live_stories.profile_id))
      )
    )
  );
drop policy if exists live_stories_self_insert on live_stories;
create policy live_stories_self_insert on live_stories
  for insert to authenticated with check (profile_id = auth.uid());
drop policy if exists live_stories_self_delete on live_stories;
create policy live_stories_self_delete on live_stories
  for delete to authenticated using (profile_id = auth.uid());

grant select, insert, delete on live_stories to authenticated;

-- Public bucket, path {user_id}/{uuid}.jpg.
insert into storage.buckets (id, name, public)
values ('stories', 'stories', true)
on conflict (id) do nothing;

drop policy if exists stories_storage_insert on storage.objects;
create policy stories_storage_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'stories'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists stories_storage_delete on storage.objects;
create policy stories_storage_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'stories' and owner_id = auth.uid()::text);
