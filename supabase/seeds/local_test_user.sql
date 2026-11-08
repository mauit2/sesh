-- Local-only test account so a fresh `supabase db reset` can be signed into
-- straight away: local-test@example.com / LocalDev1!, username localtest.
-- Seeds never reach production (`db push` sends migrations only). The
-- empty-string token columns matter: GoTrue reads them as strings and a
-- NULL breaks sign-in with a scan error.
do $$
declare
  uid uuid := 'a0000000-0000-4000-8000-000000000001';
begin
  if to_regclass('auth.users') is null or to_regclass('public.profiles') is null then
    return;
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token,
    reauthentication_token, is_sso_user, is_anonymous
  ) values (
    uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'local-test@example.com', extensions.crypt('LocalDev1!', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}', now(), now(),
    '', '', '', '', '', '', '', '', false, false
  ) on conflict (id) do nothing;

  insert into auth.identities (
    id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), uid, uid::text, 'email',
    jsonb_build_object('sub', uid::text, 'email', 'local-test@example.com', 'email_verified', true),
    now(), now(), now()
  ) on conflict (provider_id, provider) do nothing;

  insert into public.profiles (
    id, name, username, age, birthdate, sex, weight_kg, disclaimer_ack_at, disclaimer_ack_version
  ) values (
    uid, 'Local Test', 'localtest', 25, '2001-11-05', 'male', 75, now(), 'v1'
  ) on conflict (id) do nothing;
end $$;

-- Two friends for the test account so the calculator's Friends mode and the
-- friend pickers have people in them locally (62 kg F, 92 kg M).
do $$
declare
  me uuid := 'a0000000-0000-4000-8000-000000000001';
  f1 uuid := 'a0000000-0000-4000-8000-000000000002';
  f2 uuid := 'a0000000-0000-4000-8000-000000000003';
begin
  if to_regclass('auth.users') is null or to_regclass('public.friendships') is null then
    return;
  end if;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token, is_sso_user, is_anonymous)
  values
   (f1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'local-friend-1@example.com',
    extensions.crypt('LocalDev1!', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
    '', '', '', '', '', '', '', '', false, false),
   (f2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'local-friend-2@example.com',
    extensions.crypt('LocalDev1!', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
    '', '', '', '', '', '', '', '', false, false)
  on conflict (id) do nothing;
  insert into public.profiles (id, name, username, age, birthdate, sex, weight_kg, disclaimer_ack_at, disclaimer_ack_version)
  values (f1, 'Ester Local', 'esterlocal', 24, '2002-03-03', 'female', 62, now(), 'v1'),
         (f2, 'Frode Local', 'frodelocal', 27, '1999-07-07', 'male', 92, now(), 'v1')
  on conflict (id) do nothing;
  insert into public.friendships (requester_id, addressee_id, status)
  values (me, f1, 'accepted'), (f2, me, 'accepted')
  on conflict do nothing;
end $$;
