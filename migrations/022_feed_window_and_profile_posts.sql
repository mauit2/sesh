-- 022_feed_window_and_profile_posts.sql
--
-- The timeline feed shows only the last 7 days (posts still live forever on
-- profiles). Adds user_posts for the profile grid (a user's full archive,
-- visible to that user and their accepted friends).

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
    and po.created_at > now() - interval '7 days'
    and (p_before is null or po.created_at < p_before)
  order by po.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 50));
$$;

create or replace function user_posts(p_user uuid)
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
  where po.author_id = p_user
    and (
      p_user = auth.uid()
      or exists (
        select 1 from friendships f
        where f.status='accepted'
          and ((f.requester_id=auth.uid() and f.addressee_id=p_user)
            or (f.requester_id=p_user and f.addressee_id=auth.uid()))
      )
    )
  order by po.created_at desc;
$$;

revoke execute on function user_posts(uuid) from public, anon;
grant  execute on function user_posts(uuid) to authenticated;

notify pgrst, 'reload schema';
