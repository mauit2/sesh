-- 026_likes_and_comments.sql
--
-- Likes + comments on Nightline posts. Both tables are accessed only through
-- SECURITY DEFINER RPCs (RLS on, no policies = no direct client access), each
-- gated by can_see_post (author or accepted friend of the author). The feed
-- RPCs also return like_count / liked_by_me / comment_count.

create or replace function can_see_post(p_post_id uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists(
    select 1 from posts po
    where po.id = p_post_id and (
      po.author_id = auth.uid()
      or exists(select 1 from friendships f where f.status='accepted'
          and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
            or (f.requester_id=po.author_id and f.addressee_id=auth.uid())))
    )
  );
$$;
revoke execute on function can_see_post(uuid) from public, anon, authenticated;

create table if not exists post_likes (
  post_id    uuid not null references posts(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table post_likes enable row level security;

create table if not exists post_comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references posts(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists post_comments_post_idx on post_comments (post_id, created_at);
alter table post_comments enable row level security;

create or replace function set_like(p_post_id uuid, p_like boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not can_see_post(p_post_id) then raise exception 'not allowed'; end if;
  if p_like then
    insert into post_likes(post_id, user_id) values (p_post_id, auth.uid()) on conflict do nothing;
  else
    delete from post_likes where post_id=p_post_id and user_id=auth.uid();
  end if;
end; $$;

create or replace function add_comment(p_post_id uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_clean text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not can_see_post(p_post_id) then raise exception 'not allowed'; end if;
  v_clean := left(btrim(p_body), 500);
  if v_clean = '' then raise exception 'empty'; end if;
  insert into post_comments(post_id, author_id, body) values (p_post_id, auth.uid(), v_clean)
    returning id into v_id;
  return v_id;
end; $$;

create or replace function delete_comment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from post_comments c
   where c.id = p_id and (
     c.author_id = auth.uid()
     or exists(select 1 from posts po where po.id=c.post_id and po.author_id=auth.uid())
   );
end; $$;

create or replace function list_comments(p_post_id uuid)
returns table (id uuid, author_id uuid, author_name text, author_username text, author_avatar text, body text, created_at timestamptz)
language sql security definer set search_path = public as $$
  select c.id, c.author_id, pr.name, pr.username, pr.avatar_url, c.body, c.created_at
  from post_comments c join profiles pr on pr.id = c.author_id
  where c.post_id = p_post_id and can_see_post(p_post_id)
  order by c.created_at asc;
$$;

revoke execute on function set_like(uuid, boolean)   from public, anon;
revoke execute on function add_comment(uuid, text)   from public, anon;
revoke execute on function delete_comment(uuid)      from public, anon;
revoke execute on function list_comments(uuid)       from public, anon;
grant  execute on function set_like(uuid, boolean)   to authenticated;
grant  execute on function add_comment(uuid, text)   to authenticated;
grant  execute on function delete_comment(uuid)      to authenticated;
grant  execute on function list_comments(uuid)       to authenticated;

drop function if exists friends_feed(int, timestamptz);
create function friends_feed(p_limit int default 30, p_before timestamptz default null)
returns table (
  id uuid, author_id uuid, author_name text, author_username text, author_avatar text,
  recap jsonb, include_bac boolean, caption text, cover_url text, started_at timestamptz, created_at timestamptz,
  like_count int, liked_by_me boolean, comment_count int
)
language sql security definer set search_path = public
as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where (
      po.author_id = auth.uid()
      or exists (select 1 from friendships f where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
          or (f.requester_id=po.author_id and f.addressee_id=auth.uid())))
    )
    and po.created_at > now() - interval '7 days'
    and (p_before is null or po.created_at < p_before)
  order by po.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 50));
$$;

drop function if exists user_posts(uuid);
create function user_posts(p_user uuid)
returns table (
  id uuid, author_id uuid, author_name text, author_username text, author_avatar text,
  recap jsonb, include_bac boolean, caption text, cover_url text, started_at timestamptz, created_at timestamptz,
  like_count int, liked_by_me boolean, comment_count int
)
language sql security definer set search_path = public
as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where po.author_id = p_user
    and (
      p_user = auth.uid()
      or exists (select 1 from friendships f where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=p_user)
          or (f.requester_id=p_user and f.addressee_id=auth.uid())))
    )
  order by po.created_at desc;
$$;

revoke execute on function friends_feed(int, timestamptz) from public, anon;
grant  execute on function friends_feed(int, timestamptz) to authenticated;
revoke execute on function user_posts(uuid) from public, anon;
grant  execute on function user_posts(uuid) to authenticated;

notify pgrst, 'reload schema';
