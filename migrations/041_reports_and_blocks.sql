-- 041_reports_and_blocks.sql
--
-- UGC moderation (App Review guideline 1.2): users can REPORT users,
-- posts, and stories, and BLOCK users.
--
--   • reports — write-only for users; only app admins read them.
--   • blocks — blocking severs the friendship and any pending invites,
--     which (because every social surface is friendship-gated: feed,
--     stories, live pulse, friends list) removes both users from each
--     other's world. A standing block also stops re-friending from
--     either side.

create table if not exists reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid not null references profiles(id) on delete cascade,
  target_kind    text not null check (target_kind in ('user','post','story')),
  target_id      uuid not null,
  target_user_id uuid references profiles(id) on delete set null,
  reason         text,
  created_at     timestamptz not null default now()
);

alter table reports enable row level security;

drop policy if exists reports_insert_self on reports;
create policy reports_insert_self on reports
  for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists reports_admin_select on reports;
create policy reports_admin_select on reports
  for select to authenticated
  using (exists (select 1 from app_admins where user_id = auth.uid()));

grant insert on reports to authenticated;
grant select on reports to authenticated;

create table if not exists blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

alter table blocks enable row level security;

drop policy if exists blocks_self_all on blocks;
create policy blocks_self_all on blocks
  for all to authenticated
  using (blocker_id = auth.uid())
  with check (blocker_id = auth.uid());

grant select, insert, delete on blocks to authenticated;

-- Block = record + sever every connection, atomically.
create or replace function block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_user = auth.uid() then raise exception 'cannot block yourself'; end if;
  insert into blocks (blocker_id, blocked_id) values (auth.uid(), p_user)
    on conflict do nothing;
  delete from friendships
    where (requester_id = auth.uid() and addressee_id = p_user)
       or (requester_id = p_user and addressee_id = auth.uid());
  delete from invites
    where (sender_id = auth.uid() and recipient_id = p_user)
       or (sender_id = p_user and recipient_id = auth.uid());
end; $$;

create or replace function unblock_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from blocks where blocker_id = auth.uid() and blocked_id = p_user;
end; $$;

revoke execute on function block_user(uuid) from public, anon;
grant execute on function block_user(uuid) to authenticated;
revoke execute on function unblock_user(uuid) from public, anon;
grant execute on function unblock_user(uuid) to authenticated;

-- A standing block stops re-friending from either side.
create or replace function send_friend_request(p_username text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_target uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select id into v_target from profiles where lower(username) = lower(trim(p_username)) limit 1;
  if v_target is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_target = auth.uid() then return jsonb_build_object('ok', false, 'reason', 'self'); end if;

  if exists (select 1 from blocks
        where (blocker_id = auth.uid() and blocked_id = v_target)
           or (blocker_id = v_target and blocked_id = auth.uid())) then
    return jsonb_build_object('ok', false, 'reason', 'blocked');
  end if;

  if exists (select 1 from friendships where status='accepted'
        and ((requester_id=auth.uid() and addressee_id=v_target)
          or (requester_id=v_target and addressee_id=auth.uid()))) then
    return jsonb_build_object('ok', false, 'reason', 'already_friends');
  end if;

  if exists (select 1 from friendships where status='pending'
        and requester_id=v_target and addressee_id=auth.uid()) then
    update friendships set status='accepted', responded_at=now()
      where requester_id=v_target and addressee_id=auth.uid();
    return jsonb_build_object('ok', true, 'status', 'accepted');
  end if;

  insert into friendships (requester_id, addressee_id, status)
    values (auth.uid(), v_target, 'pending')
    on conflict (requester_id, addressee_id) do nothing;
  return jsonb_build_object('ok', true, 'status', 'pending');
end; $$;
