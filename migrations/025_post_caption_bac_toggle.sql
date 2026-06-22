-- 025_post_caption_bac_toggle.sql
--
-- Adds post captions and makes BAC visibility toggleable after posting.
--
-- New model: posts.recap always stores the FULL recap (real BAC). Friends can
-- no longer read posts directly — the SELECT policy is author-only — and read
-- the feed exclusively through the SECURITY DEFINER RPCs, which strip BAC at
-- read time when the author opted out (recap_display). So toggling BAC after
-- the fact is just an UPDATE of include_bac, with no privacy leak (friends
-- never see the hidden BAC, even via a direct query).

alter table posts add column if not exists caption text;

drop policy if exists posts_select_friends on posts;
drop policy if exists posts_select_own on posts;
create policy posts_select_own on posts for select to authenticated
  using (author_id = auth.uid());

drop policy if exists posts_update_own on posts;
create policy posts_update_own on posts for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());

create or replace function recap_display(p_recap jsonb, p_keep_bac boolean)
returns jsonb language sql immutable as $$
  select case when p_keep_bac then p_recap
    else jsonb_set(
           jsonb_set(coalesce(p_recap, '{}'::jsonb), '{peakBAC}', '0'::jsonb),
           '{stops}',
           coalesce((
             select jsonb_agg(jsonb_set(jsonb_set(s, '{bacOnArrival}', '0'::jsonb), '{bacOnDeparture}', '0'::jsonb))
             from jsonb_array_elements(p_recap->'stops') s
           ), '[]'::jsonb))
    end
$$;

drop function if exists friends_feed(int, timestamptz);
create function friends_feed(p_limit int default 30, p_before timestamptz default null)
returns table (
  id uuid, author_id uuid, author_name text, author_username text, author_avatar text,
  recap jsonb, include_bac boolean, caption text, cover_url text, started_at timestamptz, created_at timestamptz
)
language sql security definer set search_path = public
as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at
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
  recap jsonb, include_bac boolean, caption text, cover_url text, started_at timestamptz, created_at timestamptz
)
language sql security definer set search_path = public
as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at
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
