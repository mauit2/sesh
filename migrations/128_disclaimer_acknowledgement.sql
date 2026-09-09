-- 128: record that a user has seen and acknowledged the safety disclaimer.
--
-- The disclaimer is shown as a blocking sheet the first time an account
-- reaches the signed-in app, which for a new account is immediately after
-- sign-up. A disclaimer nobody can prove was shown is worth very little in a
-- dispute, so the acknowledgement is stamped on the profile with the time and
-- the version of the wording that was accepted.
--
-- Users who signed up before this shipped have a null stamp, so they see it
-- once on next launch. That is deliberate: the point is coverage, not
-- paperwork for new accounts only.
--
-- Applied 2026-09-09 as disclaimer_acknowledgement.

alter table profiles add column if not exists disclaimer_ack_at timestamptz;
alter table profiles add column if not exists disclaimer_ack_version text;

create or replace function public.disclaimer_state()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('ack_at', disclaimer_ack_at, 'version', disclaimer_ack_version)
    from profiles where id = auth.uid();
$$;
grant execute on function public.disclaimer_state() to authenticated;

-- Idempotent: re-acknowledging the same version keeps the original timestamp,
-- so the record shows when they FIRST accepted, which is the date that matters.
create or replace function public.disclaimer_ack(p_version text default 'v1')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  update profiles
     set disclaimer_ack_at = case
           when disclaimer_ack_version is distinct from p_version then now()
           else coalesce(disclaimer_ack_at, now()) end,
         disclaimer_ack_version = p_version
   where id = auth.uid();
  return public.disclaimer_state();
end $$;
grant execute on function public.disclaimer_ack(text) to authenticated;
