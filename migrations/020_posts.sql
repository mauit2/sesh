-- 020_posts.sql
--
-- Social timeline: users can POST a night recap so their friends see it in a
-- feed (the TIMELINE tab). Recaps are normally device-local; a post copies
-- the recap JSON to the server (photos uploaded to the `recap-photos` bucket
-- and rewritten to public URLs) and is visible to the author's accepted
-- friends only. The author chooses per-post whether to include BAC numbers.

-- Friends can read each other's profiles (name/username/avatar) — needed to
-- render authorship in the feed and friend views. (RPCs already bypass this,
-- but direct reads are convenient and safe to allow between friends.)
drop policy if exists "profiles: read friends" on profiles;
create policy "profiles: read friends"
  on profiles for select
  to authenticated
  using (
    exists (
      select 1 from friendships f
      where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=profiles.id)
          or (f.requester_id=profiles.id and f.addressee_id=auth.uid()))
    )
  );

create table if not exists posts (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references profiles(id) on delete cascade,
  recap        jsonb not null,            -- NightRecap JSON; BAC stripped when include_bac=false
  include_bac  boolean not null default false,
  cover_url    text,                      -- optional feed thumbnail (a stop photo)
  started_at   timestamptz,               -- the night's start, for display
  created_at   timestamptz not null default now()
);

create index if not exists posts_author_idx on posts (author_id, created_at desc);
create index if not exists posts_feed_idx on posts (created_at desc);

alter table posts enable row level security;

-- Read: the author, or an accepted friend of the author.
drop policy if exists posts_select_friends on posts;
create policy posts_select_friends
  on posts for select
  to authenticated
  using (
    author_id = auth.uid()
    or exists (
      select 1 from friendships f
      where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=posts.author_id)
          or (f.requester_id=posts.author_id and f.addressee_id=auth.uid()))
    )
  );

drop policy if exists posts_insert_own on posts;
create policy posts_insert_own
  on posts for insert to authenticated
  with check (author_id = auth.uid());

drop policy if exists posts_delete_own on posts;
create policy posts_delete_own
  on posts for delete to authenticated
  using (author_id = auth.uid());

-- The feed: the caller's friends' posts (and their own), newest first, with
-- author fields joined in. SECURITY DEFINER so it can read friends' profiles.
create or replace function friends_feed(p_limit int default 30, p_before timestamptz default null)
returns table (
  id uuid, author_id uuid, author_name text, author_username text, author_avatar text,
  recap jsonb, include_bac boolean, cover_url text, started_at timestamptz, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         po.recap, po.include_bac, po.cover_url, po.started_at, po.created_at
  from posts po
  join profiles pr on pr.id = po.author_id
  where (
      po.author_id = auth.uid()
      or exists (
        select 1 from friendships f
        where f.status='accepted'
          and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
            or (f.requester_id=po.author_id and f.addressee_id=auth.uid()))
      )
    )
    and (p_before is null or po.created_at < p_before)
  order by po.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 50));
$$;

revoke execute on function friends_feed(int, timestamptz) from public, anon;
grant  execute on function friends_feed(int, timestamptz) to authenticated;

-- Storage bucket for posted photos. Public-read (URLs carry UUID paths),
-- writes restricted to the uploader's own <uid>/ folder. Mirrors how the
-- existing `avatars` bucket works.
insert into storage.buckets (id, name, public)
values ('recap-photos', 'recap-photos', true)
on conflict (id) do nothing;

drop policy if exists "recap photos: insert own" on storage.objects;
create policy "recap photos: insert own"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "recap photos: delete own" on storage.objects;
create policy "recap photos: delete own"
  on storage.objects for delete to authenticated
  using (bucket_id = 'recap-photos' and (storage.foldername(name))[1] = auth.uid()::text);

notify pgrst, 'reload schema';
