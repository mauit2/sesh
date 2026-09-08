-- 121: resolve a bar from its @handle — the "follow us" QR links to
-- https://sejdel.com/b/<username>. Applied 2026-09-08 as business_by_username.
create or replace function public.business_by_username(p_username text) returns uuid
language sql stable security definer set search_path = public, private as $$
  select b.id from businesses b
  where b.username = lower(trim(p_username)) and b.status = 'approved' and private.biz_tier(b.id) <> 'none'
  limit 1
$$;
grant execute on function public.business_by_username(text) to anon, authenticated;
