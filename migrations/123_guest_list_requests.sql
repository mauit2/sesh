-- 123: the guest list. Anyone can DM a bar; in that chat a quick command sends a
-- "get on the list" request (full name, Instagram, +N, which night). The bar
-- approves or declines from the chat or from ☰ → Guest list, where approved
-- names can be shared as text or exported as CSV.
-- Applied 2026-09-08 as guest_list_requests.

create table if not exists public.list_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null check (char_length(full_name) between 2 and 80),
  instagram text not null check (char_length(instagram) between 1 and 40),
  plus_count integer not null default 0 check (plus_count between 0 and 50),
  night date not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists list_requests_business_night on public.list_requests (business_id, night);
alter table public.list_requests enable row level security;
drop policy if exists list_requests_select on public.list_requests;
create policy list_requests_select on public.list_requests for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.business_id = list_requests.business_id)
);
-- Writes only through the RPCs below.

alter table public.dm_messages add column if not exists list_request_id uuid references public.list_requests(id) on delete set null;
alter table public.dm_messages drop constraint if exists dm_messages_kind_check;
alter table public.dm_messages add constraint dm_messages_kind_check
  check (kind = any (array['text', 'story_reply', 'story_like', 'list_request']));

-- Who can I message? Friends, as before; any bar; and a bar can answer anyone who wrote to it.
create or replace function public.dm_can_message(p_other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and p_other <> auth.uid() and (
    exists (select 1 from friendships f where f.status = 'accepted'
              and ((f.requester_id = auth.uid() and f.addressee_id = p_other)
                or (f.addressee_id = auth.uid() and f.requester_id = p_other)))
    or exists (select 1 from profiles p where p.id = p_other and p.business_id is not null)
    or exists (select 1 from profiles me join dm_messages d on d.recipient_id = me.id and d.sender_id = p_other
               where me.id = auth.uid() and me.business_id is not null)
  )
$$;
revoke execute on function public.dm_can_message(uuid) from public, anon;
grant execute on function public.dm_can_message(uuid) to authenticated;

drop policy if exists dm_insert on public.dm_messages;
create policy dm_insert on public.dm_messages for insert to authenticated with check (
  sender_id = auth.uid() and sender_id <> recipient_id and kind <> 'list_request' and public.dm_can_message(recipient_id)
);

-- The people in my chats — name, handle, picture, and whether they're a bar.
-- Replaces reading profiles rows directly (which RLS only allows for friends).
create or replace function public.dm_partners(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url, 'business_id', p.business_id)), '[]'::jsonb)
  from profiles p
  where p.id = any(p_ids) and auth.uid() is not null and (
    p.id = auth.uid()
    or p.business_id is not null
    or exists (select 1 from dm_messages d where (d.sender_id = auth.uid() and d.recipient_id = p.id)
                                              or (d.recipient_id = auth.uid() and d.sender_id = p.id))
    or exists (select 1 from friendships f where f.status = 'accepted'
                 and ((f.requester_id = auth.uid() and f.addressee_id = p.id)
                   or (f.addressee_id = auth.uid() and f.requester_id = p.id)))
  )
$$;
revoke execute on function public.dm_partners(uuid[]) from public, anon;
grant execute on function public.dm_partners(uuid[]) to authenticated;

-- "Get on the list": the request row plus the DM that carries it to the bar.
create or replace function public.list_request_send(p_business uuid, p_full_name text, p_instagram text, p_plus integer, p_night date)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare v_me uuid := auth.uid(); v_account uuid; v_name text; v_insta text; v_id uuid; b businesses;
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  select * into b from businesses where id = p_business and status = 'approved';
  if b.id is null or private.biz_tier(b.id) = 'none' then raise exception 'not_on_sejdel'; end if;
  select id into v_account from profiles where business_id = b.id limit 1;
  if v_account is null then raise exception 'no_account'; end if;
  if v_account = v_me then raise exception 'own_bar'; end if;
  v_name := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  if char_length(v_name) < 2 then raise exception 'name_required'; end if;
  -- "@handle", "instagram.com/handle", "handle" → handle
  v_insta := lower(btrim(coalesce(p_instagram, '')));
  v_insta := regexp_replace(v_insta, '^(https?://)?(www\.)?instagram\.com/', '');
  v_insta := regexp_replace(v_insta, '^@+', '');
  v_insta := regexp_replace(v_insta, '[/?#].*$', '');
  if v_insta !~ '^[a-z0-9._]{1,30}$' then raise exception 'instagram_required'; end if;
  if p_plus is null or p_plus < 0 or p_plus > 50 then raise exception 'bad_party'; end if;
  if p_night is null or p_night < current_date then raise exception 'bad_night'; end if;
  if exists (select 1 from list_requests r where r.business_id = b.id and r.user_id = v_me and r.night = p_night and r.status = 'pending') then
    raise exception 'already_requested';
  end if;
  insert into list_requests (business_id, user_id, full_name, instagram, plus_count, night)
  values (b.id, v_me, v_name, v_insta, p_plus, p_night) returning id into v_id;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_me, v_account, 'list_request',
          format('🎟 Get on the list · %s · %s +%s · @%s', to_char(p_night, 'Dy FMDD Mon'), v_name, p_plus, v_insta), v_id);
  return v_id;
end $$;
revoke execute on function public.list_request_send(uuid, text, text, integer, date) from public, anon;
grant execute on function public.list_request_send(uuid, text, text, integer, date) to authenticated;

-- The bar decides; the guest hears back in the same chat (and gets the push).
create or replace function public.list_request_decide(p_request uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_me uuid := auth.uid(); r list_requests; v_status text;
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  select * into r from list_requests where id = p_request;
  if r.id is null then raise exception 'no_request'; end if;
  if not exists (select 1 from profiles p where p.id = v_me and p.business_id = r.business_id) then raise exception 'not_yours'; end if;
  v_status := case when p_approve then 'approved' else 'declined' end;
  if r.status = v_status then return; end if;
  update list_requests set status = v_status, decided_at = now() where id = r.id;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_me, r.user_id, 'text',
    case when p_approve
      then format('You''re on the list for %s — %s +%s. See you at the door 🎉', to_char(r.night, 'Dy FMDD Mon'), r.full_name, r.plus_count)
      else format('Sorry — the list for %s is full.', to_char(r.night, 'Dy FMDD Mon')) end,
    r.id);
end $$;
revoke execute on function public.list_request_decide(uuid, boolean) from public, anon;
grant execute on function public.list_request_decide(uuid, boolean) to authenticated;

-- The bar's list: every request from yesterday on, pending first within a night.
create or replace function public.list_requests_for(p_business uuid, p_from date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'business_id', r.business_id, 'user_id', r.user_id, 'full_name', r.full_name, 'instagram', r.instagram,
    'plus_count', r.plus_count, 'night', r.night, 'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at,
    'user_name', p.name, 'user_username', p.username, 'user_avatar', p.avatar_url
  ) order by r.night, (r.status <> 'pending'), r.created_at), '[]'::jsonb)
  from list_requests r join profiles p on p.id = r.user_id
  where r.business_id = p_business
    and exists (select 1 from profiles me where me.id = auth.uid() and me.business_id = p_business)
    and r.night >= coalesce(p_from, current_date - 1)
$$;
revoke execute on function public.list_requests_for(uuid, date) from public, anon;
grant execute on function public.list_requests_for(uuid, date) to authenticated;

-- business_profile: the account behind the bar, so a profile can open a chat with it.
do $$
declare src text;
begin
  src := pg_get_functiondef('public.business_profile(uuid)'::regprocedure);
  if position('''account_id''' in src) = 0 then
    src := replace(src, '''following'', exists',
      '''account_id'', (select p.id from profiles p where p.business_id = b.id limit 1), ''following'', exists');
    execute src;
  end if;
end $$;
