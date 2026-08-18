-- 108: auth pen-test remediation.
--
-- (CRITICAL) user_files(p_uid): returned storage.objects.owner = p_uid for an
-- ARBITRARY p_uid, was anon-executable, and every bucket is public — so any
-- anon caller could enumerate a victim's exact snap/story/recap file paths and
-- fetch the media from the public URL. Only the delete-account edge function
-- calls it (service_role). Lock to service_role and self-guard.
revoke execute on function public.user_files(uuid) from public, anon, authenticated;

create or replace function public.user_files(p_uid uuid)
returns table(bucket_id text, name text)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is not null and p_uid <> auth.uid() then
    raise exception 'forbidden';
  end if;
  return query
    select o.bucket_id, o.name from storage.objects o where o.owner = p_uid;
end $function$;

revoke execute on function public.user_files(uuid) from public, anon, authenticated;
grant  execute on function public.user_files(uuid) to service_role;

-- (LOW→MED) ensure_qr_token: anon could mint venue QR tokens. App calls it as
-- an authenticated user (Heat.swift). Drop anon.
revoke execute on function public.ensure_qr_token(uuid) from public;
grant  execute on function public.ensure_qr_token(uuid) to authenticated, service_role;

-- (LOW) bump_campaign_stats: anon could tamper ad analytics. Only the app
-- (authenticated) bumps stats; the public web map does not. Drop anon.
revoke execute on function public.bump_campaign_stats(uuid, integer, integer) from public;
grant  execute on function public.bump_campaign_stats(uuid, integer, integer) to authenticated, service_role;
