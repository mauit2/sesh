-- 131_moderation_queue.sql
--
-- Reports were write-only. Migration 041 created the table, the app inserts
-- into it (Nightline.swift), and nothing has ever read it — no RPC, no query,
-- no admin screen. Two reports were sitting unread when this was written. On
-- top of that, `posts` and `live_stories` had no soft-delete at all: only the
-- author could remove their own content, so honouring a takedown meant hand-
-- editing the database.
--
-- This closes the loop:
--
--   admin_reports()        the queue, with the reported content joined in
--   admin_takedown()       hide a post or story, and resolve its reports
--   admin_restore()        undo a takedown
--   admin_report_resolve() close a report without removing anything
--
-- Soft delete only works if every read path honours it. `live_stories` is read
-- straight through PostgREST, so its RLS policy carries the filter and covers
-- everything at once. `posts` is different: friends_feed, user_posts and
-- can_see_post are SECURITY DEFINER and bypass RLS, so each gets the filter
-- explicitly. can_see_post matters most — it gates likes and comments, so
-- without it people could keep interacting with content that had been removed.
--
-- Storage is left alone. A story's file is purged by the daily cleanup within
-- 24 hours anyway, and a post's cover survives; if a takedown ever needs the
-- bytes gone immediately that has to go through the Storage API, the way
-- delete-account does.

-- ── Soft delete ──────────────────────────────────────────────────────────────
alter table posts        add column if not exists deleted_at timestamptz;
alter table live_stories add column if not exists deleted_at timestamptz;

create index if not exists posts_live_idx        on posts (created_at desc) where deleted_at is null;
create index if not exists live_stories_live_idx on live_stories (created_at desc) where deleted_at is null;

-- ── Reports get an outcome ───────────────────────────────────────────────────
alter table reports add column if not exists resolved_at  timestamptz;
alter table reports add column if not exists resolved_by  uuid references profiles(id) on delete set null;
alter table reports add column if not exists action_taken text;

create index if not exists reports_open_idx on reports (created_at desc) where resolved_at is null;

-- ── Hide removed stories everywhere ──────────────────────────────────────────
-- Pure-RLS table, so this one policy is every read path.
drop policy if exists live_stories_friends_select on live_stories;
create policy live_stories_friends_select on live_stories
  for select to authenticated
  using (
    deleted_at is null
    and created_at > now() - interval '24 hours'
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

-- ── Hide removed posts everywhere ────────────────────────────────────────────
-- These three are SECURITY DEFINER and so are not covered by RLS.

create or replace function public.friends_feed(p_limit integer default 30,
                                               p_before timestamptz default null)
returns table (id uuid, author_id uuid, author_name text, author_username text,
               author_avatar text, recap jsonb, include_bac boolean, caption text,
               cover_url text, started_at timestamptz, created_at timestamptz,
               like_count integer, liked_by_me boolean, comment_count integer)
language sql security definer set search_path = public as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where po.deleted_at is null
    and (
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

create or replace function public.user_posts(p_user uuid)
returns table (id uuid, author_id uuid, author_name text, author_username text,
               author_avatar text, recap jsonb, include_bac boolean, caption text,
               cover_url text, started_at timestamptz, created_at timestamptz,
               like_count integer, liked_by_me boolean, comment_count integer)
language sql security definer set search_path = public as $$
  select po.id, po.author_id, pr.name, pr.username, pr.avatar_url,
         recap_display(po.recap, po.include_bac), po.include_bac, po.caption,
         po.cover_url, po.started_at, po.created_at,
         (select count(*) from post_likes pl where pl.post_id=po.id)::int,
         exists(select 1 from post_likes pl where pl.post_id=po.id and pl.user_id=auth.uid()),
         (select count(*) from post_comments pc where pc.post_id=po.id)::int
  from posts po
  join profiles pr on pr.id = po.author_id
  where po.deleted_at is null
    and po.author_id = p_user
    and (
      p_user = auth.uid()
      or exists (select 1 from friendships f where f.status='accepted'
        and ((f.requester_id=auth.uid() and f.addressee_id=p_user)
          or (f.requester_id=p_user and f.addressee_id=auth.uid())))
    )
  order by po.created_at desc;
$$;

-- Gates likes and comments: without the filter, a removed post stays
-- interactive.
create or replace function public.can_see_post(p_post_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from posts po
    where po.id = p_post_id
      and po.deleted_at is null
      and (
        po.author_id = auth.uid()
        or exists(select 1 from friendships f where f.status='accepted'
            and ((f.requester_id=auth.uid() and f.addressee_id=po.author_id)
              or (f.requester_id=po.author_id and f.addressee_id=auth.uid())))
      )
  );
$$;

-- ── The queue ────────────────────────────────────────────────────────────────
-- Open reports newest first, with enough of the reported thing attached to
-- decide without a second round trip. Deleted content still shows here — an
-- admin needs to see what they removed.
create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table (
  id uuid, created_at timestamptz,
  reporter_id uuid, reporter_name text, reporter_username text,
  target_kind text, target_id uuid,
  target_user_id uuid, target_name text, target_username text,
  reason text,
  content_caption text, content_ref text, content_created_at timestamptz,
  content_deleted_at timestamptz, content_gone boolean,
  resolved_at timestamptz, action_taken text
)
language sql security definer set search_path = public as $$
  select r.id, r.created_at,
         r.reporter_id, rp.name, rp.username,
         r.target_kind, r.target_id,
         r.target_user_id, tp.name, tp.username,
         r.reason,
         case r.target_kind when 'post' then po.caption    when 'story' then ls.caption      end,
         case r.target_kind when 'post' then po.cover_url  when 'story' then ls.storage_path end,
         case r.target_kind when 'post' then po.created_at when 'story' then ls.created_at   end,
         case r.target_kind when 'post' then po.deleted_at when 'story' then ls.deleted_at   end,
         -- already gone from the database entirely (expired story, deleted account)
         r.target_kind in ('post','story') and po.id is null and ls.id is null,
         r.resolved_at, r.action_taken
    from reports r
    join profiles rp on rp.id = r.reporter_id
    left join profiles tp on tp.id = r.target_user_id
    left join posts po on r.target_kind = 'post'  and po.id = r.target_id
    left join live_stories ls on r.target_kind = 'story' and ls.id = r.target_id
   where exists (select 1 from app_admins where user_id = auth.uid())
     and (p_include_resolved or r.resolved_at is null)
   order by r.created_at desc
   limit 500;
$$;

-- ── Acting on it ─────────────────────────────────────────────────────────────
-- Removing content closes every open report against it, so the same item does
-- not sit in the queue once per reporter.
create or replace function public.admin_takedown(p_kind text, p_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_kind = 'post' then
    update posts set deleted_at = now() where id = p_id and deleted_at is null;
  elsif p_kind = 'story' then
    update live_stories set deleted_at = now() where id = p_id and deleted_at is null;
  else
    raise exception 'bad_kind';
  end if;
  update reports
     set resolved_at = now(), resolved_by = auth.uid(),
         action_taken = coalesce(nullif(trim(p_reason), ''), 'content removed')
   where target_kind = p_kind and target_id = p_id and resolved_at is null;
end $$;

create or replace function public.admin_restore(p_kind text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_kind = 'post' then
    update posts set deleted_at = null where id = p_id;
  elsif p_kind = 'story' then
    update live_stories set deleted_at = null where id = p_id;
  else
    raise exception 'bad_kind';
  end if;
end $$;

-- Close a report without removing anything — the usual outcome.
create or replace function public.admin_report_resolve(p_report uuid, p_action text default 'no action')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;
  update reports
     set resolved_at = now(), resolved_by = auth.uid(),
         action_taken = coalesce(nullif(trim(p_action), ''), 'no action')
   where id = p_report and resolved_at is null;
end $$;

revoke all on function public.admin_reports(boolean) from public;
revoke all on function public.admin_takedown(text, uuid, text) from public;
revoke all on function public.admin_restore(text, uuid) from public;
revoke all on function public.admin_report_resolve(uuid, text) from public;
grant execute on function public.admin_reports(boolean)          to authenticated;
grant execute on function public.admin_takedown(text, uuid, text) to authenticated;
grant execute on function public.admin_restore(text, uuid)        to authenticated;
grant execute on function public.admin_report_resolve(uuid, text) to authenticated;

notify pgrst, 'reload schema';
