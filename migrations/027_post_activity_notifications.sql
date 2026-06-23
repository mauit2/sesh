-- 027_post_activity_notifications.sql
--
-- Bell notifications derived live from likes/comments on the caller's posts in
-- the last 24h, grouped by (post, kind). Multiple likers/commenters on the
-- same post condense into one row with the actor list attached. No separate
-- table or trigger — the 24h window + condensing fall out of the query, so
-- notifications "expire" automatically.

create or replace function my_post_activity()
returns table (
  post_id uuid, kind text, actor_count int, latest_at timestamptz, actors jsonb, cover_url text
)
language sql security definer set search_path = public as $$
  with acts as (
    select pl.post_id, 'like'::text as kind, pl.user_id as actor_id, pl.created_at
    from post_likes pl join posts po on po.id = pl.post_id
    where po.author_id = auth.uid() and pl.user_id <> auth.uid()
      and pl.created_at > now() - interval '24 hours'
    union all
    select pc.post_id, 'comment'::text, pc.author_id, pc.created_at
    from post_comments pc join posts po on po.id = pc.post_id
    where po.author_id = auth.uid() and pc.author_id <> auth.uid()
      and pc.created_at > now() - interval '24 hours'
  ),
  per_actor as (
    select post_id, kind, actor_id, max(created_at) as latest
    from acts group by post_id, kind, actor_id
  )
  select pa.post_id, pa.kind, count(*)::int as actor_count, max(pa.latest) as latest_at,
    jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name,
              'username', pr.username, 'avatar', pr.avatar_url) order by pa.latest desc) as actors,
    po.cover_url
  from per_actor pa
  join profiles pr on pr.id = pa.actor_id
  join posts po on po.id = pa.post_id
  group by pa.post_id, pa.kind, po.cover_url
  order by max(pa.latest) desc;
$$;

revoke execute on function my_post_activity() from public, anon;
grant  execute on function my_post_activity() to authenticated;

notify pgrst, 'reload schema';
