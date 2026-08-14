-- 098 — find friends from the address book, without an address book upload.
--
-- HOW THIS AVOIDS HOLDING PEOPLE'S CONTACT DATA
--
-- The server never sees a phone number or an email address. The client
-- normalises each value, salts it with an app constant, SHA-256s it, and
-- sends only the digest. Own digests are stored here at signup; contact
-- digests are sent to match_contacts(), compared in one query, and
-- discarded — nothing about a non-user is ever written down. That matters
-- legally as much as technically: the contacts in someone's phone never
-- consented to us processing their data, so we don't.
--
-- HONEST LIMIT: a phone-number digest is brute-forceable. There are only
-- ~10^9 numbers per country, so anyone who steals this table can recover
-- the numbers by hashing candidates. The app salt raises the cost of
-- generic rainbow tables and nothing more. That is the accepted trade in
-- every hash-based contact-discovery design (Signal has written at length
-- about failing to do better). It is why:
--   • raw numbers are NEVER stored — a breach leaks digests, not numbers,
--   • the table is readable by nobody but its owner,
--   • matching runs in a definer function that returns profiles, never keys.
--
-- Multiple digests per user on purpose ("kinds" and variants): a number
-- written +46 70 123 45 67 in one phone and 070-1234567 in another must
-- still match, so the client emits every plausible normalisation and any
-- overlap counts.

create table if not exists contact_keys (
  profile_id uuid not null references profiles(id) on delete cascade,
  key_hash   text not null,
  kind       text not null check (kind in ('phone', 'email')),
  created_at timestamptz not null default now(),
  primary key (profile_id, key_hash)
);

comment on table contact_keys is
  'Salted SHA-256 digests of a user''s own phone/email, for contact discovery (098). Never raw values; owner-readable only; matching goes through match_contacts().';

-- The matching lookup goes hash → profile, so that is the index.
create index if not exists idx_contact_keys_hash on contact_keys (key_hash);

alter table contact_keys enable row level security;

-- Owner-only, both directions. No policy lets one user read another's
-- digests — discovery must go through the definer function below, which
-- returns profiles and never keys.
drop policy if exists "contact keys: self read" on contact_keys;
create policy "contact keys: self read" on contact_keys
  for select using (profile_id = auth.uid());
drop policy if exists "contact keys: self write" on contact_keys;
create policy "contact keys: self write" on contact_keys
  for insert with check (profile_id = auth.uid());
drop policy if exists "contact keys: self delete" on contact_keys;
create policy "contact keys: self delete" on contact_keys
  for delete using (profile_id = auth.uid());

-- ---------------------------------------------------------------- publish
-- Replace my own digest set. Called after signup and whenever the user
-- adds or changes a phone number.
create or replace function public.set_my_contact_keys(p_keys jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_keys is null or jsonb_typeof(p_keys) <> 'array' then
    raise exception 'bad_request';
  end if;
  if jsonb_array_length(p_keys) > 12 then raise exception 'too_many'; end if;

  delete from contact_keys where profile_id = v_uid;
  insert into contact_keys (profile_id, key_hash, kind)
  select v_uid, e->>'hash', e->>'kind'
  from jsonb_array_elements(p_keys) e
  where e->>'hash' ~ '^[0-9a-f]{64}$'          -- a hex digest and nothing else
    and e->>'kind' in ('phone', 'email')
  on conflict (profile_id, key_hash) do nothing;

  select count(*) into v_n from contact_keys where profile_id = v_uid;
  return v_n;
end $$;

revoke all on function public.set_my_contact_keys(jsonb) from public;
grant execute on function public.set_my_contact_keys(jsonb) to authenticated;

-- ----------------------------------------------------------------- match
-- Hand me digests from an address book; get back the people they belong to.
-- Deliberately narrow: profiles only, no digests echoed, self excluded,
-- people I already know excluded (nothing to add), and blocks respected in
-- both directions so a blocked user can't resurface through the contact
-- sheet.
create or replace function public.match_contacts(p_hashes text[])
returns table (
  id uuid,
  name text,
  username text,
  avatar_url text
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  if p_hashes is null or array_length(p_hashes, 1) is null then return; end if;
  -- A whole address book is a few thousand entries; more than this is
  -- someone probing, not someone finding their friends.
  if array_length(p_hashes, 1) > 4000 then raise exception 'too_many'; end if;
  if not rate_limit_hit('contact_match', v_uid::text, 40, '1 hour') then
    raise exception 'rate_limited';
  end if;

  return query
    select distinct p.id, p.name, p.username, p.avatar_url
    from contact_keys k
    join profiles p on p.id = k.profile_id
    where k.key_hash = any (p_hashes)
      and p.id <> v_uid
      -- Any existing edge hides the row: an accepted friend has nothing to
      -- add, and a pending request in EITHER direction would otherwise
      -- offer an "Add" button that just errors on the duplicate.
      and not exists (
        select 1 from friendships f
        where ((f.requester_id = v_uid and f.addressee_id = p.id)
            or (f.requester_id = p.id and f.addressee_id = v_uid))
          and f.status in ('pending', 'accepted')
      )
      and not exists (
        select 1 from blocks b
        where (b.blocker_id = v_uid and b.blocked_id = p.id)
           or (b.blocker_id = p.id and b.blocked_id = v_uid)
      );
end $$;

revoke all on function public.match_contacts(text[]) from public;
grant execute on function public.match_contacts(text[]) to authenticated;
