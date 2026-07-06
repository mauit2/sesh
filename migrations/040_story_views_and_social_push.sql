-- 040_story_views_and_social_push.sql
--
-- 1. STORY VIEWS: who watched a story. Viewers record a row when a story
--    page is shown; only the story's AUTHOR can read the audience (plus a
--    viewer can see their own rows). Rows die with the story (cascade),
--    so the daily story purge cleans these too.
--
-- 2. SOCIAL PUSH: notify accepted friends when someone posts a story or
--    a night to the feed — same pg_net → send-push pipeline as likes,
--    comments, and invites (migration 028).

create table if not exists story_views (
  story_id  uuid not null references live_stories(id) on delete cascade,
  viewer_id uuid not null references profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);

alter table story_views enable row level security;

-- A viewer may record that THEY watched a story they can actually see
-- (the live_stories select policy re-checks friendship + freshness).
drop policy if exists story_views_insert_self on story_views;
create policy story_views_insert_self on story_views
  for insert to authenticated
  with check (
    viewer_id = auth.uid()
    and exists (select 1 from live_stories s where s.id = story_views.story_id)
  );
-- The story's author sees the audience; viewers see their own rows.
drop policy if exists story_views_select on story_views;
create policy story_views_select on story_views
  for select to authenticated
  using (
    viewer_id = auth.uid()
    or exists (
      select 1 from live_stories s
      where s.id = story_views.story_id and s.profile_id = auth.uid()
    )
  );

grant select, insert on story_views to authenticated;

-- ---------------------------------------------------------------------------
-- Push: story posted → notify friends
-- ---------------------------------------------------------------------------

create or replace function on_story_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_friend uuid; fr record;
begin
  select coalesce(nullif(name, ''), nullif(username, ''), 'A friend')
    into v_name from profiles where id = NEW.profile_id;
  for fr in
    select * from friendships f
    where f.status = 'accepted'
      and (f.requester_id = NEW.profile_id or f.addressee_id = NEW.profile_id)
  loop
    v_friend := case when fr.requester_id = NEW.profile_id
                     then fr.addressee_id else fr.requester_id end;
    perform private.notify_push(
      v_friend,
      v_name || ' posted a story',
      'Catch it in TONIGHT before it''s gone.',
      jsonb_build_object('type', 'story', 'author_id', NEW.profile_id)
    );
  end loop;
  return NEW;
end; $$;

drop trigger if exists trg_story_notify on live_stories;
create trigger trg_story_notify
  after insert on live_stories
  for each row execute function on_story_notify();

-- ---------------------------------------------------------------------------
-- Push: night posted to the feed → notify friends
-- ---------------------------------------------------------------------------

create or replace function on_post_notify() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_name text; v_friend uuid; fr record;
begin
  select coalesce(nullif(name, ''), nullif(username, ''), 'A friend')
    into v_name from profiles where id = NEW.author_id;
  for fr in
    select * from friendships f
    where f.status = 'accepted'
      and (f.requester_id = NEW.author_id or f.addressee_id = NEW.author_id)
  loop
    v_friend := case when fr.requester_id = NEW.author_id
                     then fr.addressee_id else fr.requester_id end;
    perform private.notify_push(
      v_friend,
      v_name || ' posted their night',
      'A fresh recap just landed on the Nightline.',
      jsonb_build_object('type', 'post', 'post_id', NEW.id)
    );
  end loop;
  return NEW;
end; $$;

drop trigger if exists trg_post_notify on posts;
create trigger trg_post_notify
  after insert on posts
  for each row execute function on_post_notify();
