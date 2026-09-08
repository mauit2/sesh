-- 124: the guest list, second pass. Bars pick which weekdays they take the
-- list (so no requests for nights they're closed). Business+ bars can
-- auto-approve favourites and block people — those requests are decided
-- the moment they arrive, with the same reply the bar would have sent.
-- Applied 2026-09-08 as guest_list_nights_flags.

alter table public.businesses add column if not exists list_days smallint[] not null default '{1,2,3,4,5,6,7}';

create table if not exists public.list_guest_flags (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  flag text not null check (flag in ('favorite', 'blocked')),
  created_at timestamptz not null default now(),
  primary key (business_id, user_id)
);
alter table public.list_guest_flags enable row level security;
drop policy if exists list_guest_flags_select on public.list_guest_flags;
create policy list_guest_flags_select on public.list_guest_flags for select to authenticated using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.business_id = list_guest_flags.business_id)
);

-- The bar's answer, as a DM from the bar to the guest.
create or replace function private.list_request_reply(p_request uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare r list_requests; v_account uuid;
begin
  select * into r from list_requests where id = p_request;
  if r.id is null or r.status = 'pending' then return; end if;
  select id into v_account from profiles where business_id = r.business_id limit 1;
  if v_account is null then return; end if;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_account, r.user_id, 'text',
    case when r.status = 'approved'
      then format('You''re on the list for %s — %s +%s. See you at the door 🎉', to_char(r.night, 'Dy FMDD Mon'), r.full_name, r.plus_count)
      else format('Sorry — the list for %s is full.', to_char(r.night, 'Dy FMDD Mon')) end,
    r.id);
end $$;

create or replace function public.list_request_send(p_business uuid, p_full_name text, p_instagram text, p_plus integer, p_night date)
returns uuid language plpgsql security definer set search_path = public, private as $$
declare v_me uuid := auth.uid(); v_account uuid; v_name text; v_insta text; v_id uuid; b businesses; v_flag text; v_status text := 'pending';
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  select * into b from businesses where id = p_business and status = 'approved';
  if b.id is null or private.biz_tier(b.id) = 'none' then raise exception 'not_on_sejdel'; end if;
  select id into v_account from profiles where business_id = b.id limit 1;
  if v_account is null then raise exception 'no_account'; end if;
  if v_account = v_me then raise exception 'own_bar'; end if;
  v_name := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  if char_length(v_name) < 2 then raise exception 'name_required'; end if;
  v_insta := lower(btrim(coalesce(p_instagram, '')));
  v_insta := regexp_replace(v_insta, '^(https?://)?(www\.)?instagram\.com/', '');
  v_insta := regexp_replace(v_insta, '^@+', '');
  v_insta := regexp_replace(v_insta, '[/?#].*$', '');
  if v_insta !~ '^[a-z0-9._]{1,30}$' then raise exception 'instagram_required'; end if;
  if p_plus is null or p_plus < 0 or p_plus > 50 then raise exception 'bad_party'; end if;
  if p_night is null or p_night < current_date then raise exception 'bad_night'; end if;
  if not (extract(isodow from p_night)::smallint = any (b.list_days)) then raise exception 'closed_night'; end if;
  if exists (select 1 from list_requests r where r.business_id = b.id and r.user_id = v_me and r.night = p_night and r.status = 'pending') then
    raise exception 'already_requested';
  end if;
  -- Business+ decides regulars and blocked guests on the spot.
  if private.biz_tier(b.id) = 'plus' then
    select flag into v_flag from list_guest_flags where business_id = b.id and user_id = v_me;
    v_status := case v_flag when 'favorite' then 'approved' when 'blocked' then 'declined' else 'pending' end;
  end if;
  insert into list_requests (business_id, user_id, full_name, instagram, plus_count, night, status, decided_at)
  values (b.id, v_me, v_name, v_insta, p_plus, p_night, v_status, case when v_status = 'pending' then null else now() end)
  returning id into v_id;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_me, v_account, 'list_request',
          format('🎟 Get on the list · %s · %s +%s · @%s', to_char(p_night, 'Dy FMDD Mon'), v_name, p_plus, v_insta), v_id);
  if v_status <> 'pending' then perform private.list_request_reply(v_id); end if;
  return v_id;
end $$;

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
  perform private.list_request_reply(r.id);
end $$;

-- Which weekdays the bar takes the list (ISO: 1 = Monday … 7 = Sunday).
create or replace function public.business_set_list_days(p_business uuid, p_days smallint[]) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from profiles p where p.id = auth.uid() and p.business_id = p_business) then raise exception 'not_yours'; end if;
  if p_days is null or exists (select 1 from unnest(p_days) d where d < 1 or d > 7) then raise exception 'bad_days'; end if;
  update businesses set list_days = (select coalesce(array_agg(distinct d order by d), '{}') from unnest(p_days) d) where id = p_business;
end $$;
revoke execute on function public.business_set_list_days(uuid, smallint[]) from public, anon;
grant execute on function public.business_set_list_days(uuid, smallint[]) to authenticated;

-- Favourite (auto-approved) or block someone; null clears. Business+ only.
create or replace function public.list_guest_flag(p_business uuid, p_user uuid, p_flag text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from profiles p where p.id = auth.uid() and p.business_id = p_business) then raise exception 'not_yours'; end if;
  if private.biz_tier(p_business) <> 'plus' then raise exception 'plus_required'; end if;
  if p_flag is null then
    delete from list_guest_flags where business_id = p_business and user_id = p_user;
  else
    if p_flag not in ('favorite', 'blocked') then raise exception 'bad_flag'; end if;
    insert into list_guest_flags (business_id, user_id, flag) values (p_business, p_user, p_flag)
    on conflict (business_id, user_id) do update set flag = excluded.flag, created_at = now();
  end if;
end $$;
revoke execute on function public.list_guest_flag(uuid, uuid, text) from public, anon;
grant execute on function public.list_guest_flag(uuid, uuid, text) to authenticated;

create or replace function public.list_guest_flags_for(p_business uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', f.user_id, 'flag', f.flag, 'created_at', f.created_at,
    'name', p.name, 'username', p.username, 'avatar_url', p.avatar_url,
    'last_name', (select r.full_name from list_requests r where r.business_id = f.business_id and r.user_id = f.user_id order by r.created_at desc limit 1),
    'instagram', (select r.instagram from list_requests r where r.business_id = f.business_id and r.user_id = f.user_id order by r.created_at desc limit 1)
  ) order by f.flag, p.name), '[]'::jsonb)
  from list_guest_flags f join profiles p on p.id = f.user_id
  where f.business_id = p_business
    and exists (select 1 from profiles me where me.id = auth.uid() and me.business_id = p_business)
$$;
revoke execute on function public.list_guest_flags_for(uuid) from public, anon;
grant execute on function public.list_guest_flags_for(uuid) to authenticated;

-- The bar's list now carries each guest's flag.
create or replace function public.list_requests_for(p_business uuid, p_from date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id, 'business_id', r.business_id, 'user_id', r.user_id, 'full_name', r.full_name, 'instagram', r.instagram,
    'plus_count', r.plus_count, 'night', r.night, 'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at,
    'user_name', p.name, 'user_username', p.username, 'user_avatar', p.avatar_url,
    'flag', (select f.flag from list_guest_flags f where f.business_id = r.business_id and f.user_id = r.user_id)
  ) order by r.night, (r.status <> 'pending'), r.created_at), '[]'::jsonb)
  from list_requests r join profiles p on p.id = r.user_id
  where r.business_id = p_business
    and exists (select 1 from profiles me where me.id = auth.uid() and me.business_id = p_business)
    and r.night >= coalesce(p_from, current_date - 1)
$$;

-- list_days on the public profile (the request sheet) and the owner's overview.
do $$
declare src text;
begin
  src := pg_get_functiondef('public.business_profile(uuid)'::regprocedure);
  if position('''list_days''' in src) = 0 then
    src := replace(src, '''followers'', (select count', '''list_days'', b.list_days, ''followers'', (select count');
    execute src;
  end if;
  src := pg_get_functiondef('public.business_overview(uuid)'::regprocedure);
  if position('''list_days''' in src) = 0 then
    src := replace(src, '''qr_token'', case when v_tier <> ''none'' then v.qr_token end)',
      '''qr_token'', case when v_tier <> ''none'' then v.qr_token end, ''list_days'', b.list_days)');
    execute src;
  end if;
end $$;
