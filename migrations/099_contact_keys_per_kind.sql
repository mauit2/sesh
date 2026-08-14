-- 099 — replace contact keys PER KIND, not wholesale.
--
-- 098's set_my_contact_keys deleted every key the caller had before
-- inserting. That is wrong the moment the two kinds are published from
-- different places, which is exactly the design: the email digest is
-- published automatically at launch (we always know the account's email),
-- while the phone digest only appears when the user actually types a number.
-- With replace-all, the launch publish would silently wipe the phone key and
-- the user would quietly stop being findable — the worst kind of bug,
-- because nothing errors and no screen looks wrong.
--
-- Per-kind replacement also means we never have to store the user's raw
-- phone number anywhere, on the server OR the device, just to be able to
-- re-publish the email key later. Nothing to leak.

create or replace function public.set_my_contact_keys(p_keys jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid := auth.uid(); v_n integer; v_kinds text[];
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_keys is null or jsonb_typeof(p_keys) <> 'array' then
    raise exception 'bad_request';
  end if;
  if jsonb_array_length(p_keys) > 12 then raise exception 'too_many'; end if;

  -- Which kinds is this call authoritative for? Only those get cleared.
  select coalesce(array_agg(distinct e->>'kind'), '{}')
    into v_kinds
  from jsonb_array_elements(p_keys) e
  where e->>'kind' in ('phone', 'email');

  if array_length(v_kinds, 1) is null then return 0; end if;

  delete from contact_keys
   where profile_id = v_uid and kind = any (v_kinds);

  insert into contact_keys (profile_id, key_hash, kind)
  select v_uid, e->>'hash', e->>'kind'
  from jsonb_array_elements(p_keys) e
  where e->>'hash' ~ '^[0-9a-f]{64}$'
    and e->>'kind' = any (v_kinds)
  on conflict (profile_id, key_hash) do nothing;

  select count(*) into v_n from contact_keys where profile_id = v_uid;
  return v_n;
end $$;

-- Let a user stop being discoverable without deleting their account. The
-- delete policy from 098 already allows this from the client, but a named
-- function is what a Settings toggle should call — and it makes the intent
-- auditable.
create or replace function public.clear_my_contact_keys()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  delete from contact_keys where profile_id = auth.uid();
end $$;

revoke all on function public.clear_my_contact_keys() from public;
grant execute on function public.clear_my_contact_keys() to authenticated;
