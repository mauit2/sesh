-- 129: the Instagram handle on a guest-list request becomes optional.
--
-- The handle was required, and it is effectively a link to a public profile:
-- it can tell a venue far more about someone than a door list needs. Asking
-- for it is fine, requiring it is not.
--
-- A blank handle now stores NULL rather than being rejected. Anything the
-- guest does supply is still normalised (a pasted profile URL, a leading @,
-- trailing path) and must look like a real handle, so the bar never receives
-- a half-typed URL. The chat message drops the "· @handle" tail when there
-- is none.
--
-- Applied 2026-09-09 as guest_list_instagram_optional.

alter table list_requests alter column instagram drop not null;

create or replace function public.list_request_send(p_business uuid, p_full_name text, p_instagram text, p_plus integer, p_night date)
returns uuid language plpgsql security definer set search_path to 'public', 'private' as $function$
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
  if v_insta = '' then
    v_insta := null;
  elsif v_insta !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'instagram_invalid';
  end if;

  if p_plus is null or p_plus < 0 or p_plus > 50 then raise exception 'bad_party'; end if;
  if p_night is null or p_night < current_date then raise exception 'bad_night'; end if;
  if not (extract(isodow from p_night)::smallint = any (b.list_days)) then raise exception 'closed_night'; end if;
  if exists (select 1 from list_requests r where r.business_id = b.id and r.user_id = v_me and r.night = p_night and r.status = 'pending') then
    raise exception 'already_requested';
  end if;
  if private.biz_tier(b.id) = 'plus' then
    select flag into v_flag from list_guest_flags where business_id = b.id and user_id = v_me;
    v_status := case v_flag when 'favorite' then 'approved' when 'blocked' then 'declined' else 'pending' end;
  end if;
  insert into list_requests (business_id, user_id, full_name, instagram, plus_count, night, status, decided_at)
  values (b.id, v_me, v_name, v_insta, p_plus, p_night, v_status, case when v_status = 'pending' then null else now() end)
  returning id into v_id;
  insert into dm_messages (sender_id, recipient_id, kind, body, list_request_id)
  values (v_me, v_account, 'list_request',
          format('🎟 Get on the list · %s · %s +%s%s', to_char(p_night, 'Dy FMDD Mon'), v_name, p_plus,
                 case when v_insta is null then '' else ' · @' || v_insta end), v_id);
  if v_status <> 'pending' then perform private.list_request_reply(v_id); end if;
  return v_id;
end $function$;
