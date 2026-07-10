-- 045_event_fixes.sql
--
-- Two production bugs from the first events test drive:
--
-- 1. Cover uploads died with "new row violates row-level security policy
--    for table objects". Root cause: the `authenticated` role has NO
--    USAGE on schema `private`, so any RLS policy that (directly or via
--    another table's policies) calls a private.* helper fails. We don't
--    grant usage on private — that would expose notify_push to users.
--    Instead the membership/host probes move to public as SECURITY
--    DEFINER functions, mirroring the proven is_session_member pattern,
--    and every event policy points at them.
--
-- 2. Mode toggles (calc/byob, host/everyone) snapped back: the client's
--    Encodable omits nil optionals, PostgREST then finds no function
--    matching the reduced argument list (PGRST202) and the write silently
--    fails. set_event_modes/update_event_plan get DEFAULT NULL params so
--    partial argument lists match.

-- ─── helpers out of private, into public ───────────────────────────────

create or replace function public.is_event_member(p_event uuid, p_user uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from event_members m
    where m.event_id = p_event and m.profile_id = p_user
  );
$$;

create or replace function public.is_event_host(p_event uuid, p_user uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from events e
    where e.id = p_event and e.host_id = p_user
  );
$$;

grant execute on function public.is_event_member(uuid, uuid) to authenticated;
grant execute on function public.is_event_host(uuid, uuid) to authenticated;

drop policy if exists events_select on public.events;
create policy events_select on public.events
  for select using (
    host_id = auth.uid() or public.is_event_member(id, auth.uid())
  );

drop policy if exists event_members_select on public.event_members;
create policy event_members_select on public.event_members
  for select using (
    profile_id = auth.uid()
    or public.is_event_member(event_id, auth.uid())
  );

drop policy if exists event_covers_insert on storage.objects;
create policy event_covers_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'event-covers'
    and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid())
  );

drop policy if exists event_covers_update on storage.objects;
create policy event_covers_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'event-covers'
    and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid())
  )
  with check (
    bucket_id = 'event-covers'
    and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid())
  );

drop policy if exists event_covers_delete on storage.objects;
create policy event_covers_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'event-covers'
    and public.is_event_host(((storage.foldername(name))[1])::uuid, auth.uid())
  );

drop function if exists private.is_event_host(uuid, uuid);
drop function if exists private.is_event_member(uuid, uuid);

-- ─── partial-update RPCs need defaults ─────────────────────────────────

create or replace function public.set_event_modes(
  p_event uuid, p_plan_mode text default null, p_edit_mode text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_plan_mode is not null and p_plan_mode not in ('calc', 'byob') then
    raise exception 'invalid plan_mode';
  end if;
  if p_edit_mode is not null and p_edit_mode not in ('host', 'everyone') then
    raise exception 'invalid edit_mode';
  end if;
  update events
     set plan_mode = coalesce(p_plan_mode, plan_mode),
         edit_mode = coalesce(p_edit_mode, edit_mode)
   where id = p_event and host_id = auth.uid();
end; $$;

create or replace function public.update_event_plan(
  p_event uuid, p_target_bac numeric default null,
  p_duration_hours numeric default null, p_nights integer default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set target_bac     = coalesce(p_target_bac, target_bac),
         duration_hours = coalesce(p_duration_hours, duration_hours),
         nights         = coalesce(p_nights, nights)
   where id = p_event and private.can_edit_event(p_event, auth.uid());
end; $$;
