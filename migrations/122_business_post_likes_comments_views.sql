-- 122: likes, comments and views on bars' posts, so a post opens like any post.
-- Applied 2026-09-08 as business_post_likes_comments_views.
create table if not exists public.business_post_likes (
  post_id uuid not null references public.business_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.business_post_likes enable row level security;
create table if not exists public.business_post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.business_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
alter table public.business_post_comments enable row level security;
-- private.business_post_visible(post), private.business_post_counts(post) → {like_count, liked_by_me, comment_count, views}
-- business_post_like(post, on) → count · business_post_comment(post, body) → id
-- business_post_delete_comment(comment) (own, or the bar's owner) · business_post_comments(post)
-- business_feed / business_profile / business_overview posts carry the counts;
-- views = campaign_stats impressions keyed by the post id (bump_campaign_stats).
