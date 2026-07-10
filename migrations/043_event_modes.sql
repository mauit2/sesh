-- 043_event_modes.sql
--
-- Event planning feedback round:
--  * plan_mode: 'calc' (host builds a calculated shopping list) or
--    'byob' (everyone adds what they're bringing; the pool is the list)
--  * edit_mode: 'host' (only the host edits the plan) or 'everyone'
--    (any going member can edit the list, tier and window)
--  * byo: JSONB dict keyed by profile uuid → {container: count}, each
--    member writes only their own slice via set_event_byo

alter table public.events
  add column if not exists plan_mode text not null default 'calc'
    check (plan_mode in ('calc', 'byob')),
  add column if not exists edit_mode text not null default 'host'
    check (edit_mode in ('host', 'everyone')),
  add column if not exists byo jsonb not null default '{}'::jsonb;

-- Who may edit the calculated plan (list, tier, window)?
create or replace function private.can_edit_event(p_event uuid, p_user uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from events e
    where e.id = p_event
      and (
        e.host_id = p_user
        or (
          e.edit_mode = 'everyone'
          and exists (
            select 1 from event_members m
            where m.event_id = p_event
              and m.profile_id = p_user
              and m.status = 'going'
          )
        )
      )
  );
$$;

-- Host-only: flip the planning / permission modes.
create or replace function public.set_event_modes(
  p_event uuid, p_plan_mode text, p_edit_mode text
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

-- Widen supplies + plan edits from host-only to can_edit_event.
create or replace function public.set_event_supplies(p_event uuid, p_supplies jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set supplies = coalesce(p_supplies, '{}'::jsonb)
   where id = p_event and private.can_edit_event(p_event, auth.uid());
end; $$;

create or replace function public.update_event_plan(
  p_event uuid, p_target_bac numeric, p_duration_hours numeric, p_nights integer
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set target_bac     = coalesce(p_target_bac, target_bac),
         duration_hours = coalesce(p_duration_hours, duration_hours),
         nights         = coalesce(p_nights, nights)
   where id = p_event and private.can_edit_event(p_event, auth.uid());
end; $$;

-- Any going member writes their own bring-list slice.
create or replace function public.set_event_byo(p_event uuid, p_items jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set byo = jsonb_set(
           coalesce(byo, '{}'::jsonb),
           array[auth.uid()::text],
           coalesce(p_items, '{}'::jsonb)
         )
   where id = p_event
     and exists (
       select 1 from event_members m
       where m.event_id = p_event
         and m.profile_id = auth.uid()
         and m.status = 'going'
     );
end; $$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'set_event_modes(uuid,text,text)',
    'set_event_byo(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function public.%s from public', fn);
    execute format('revoke execute on function public.%s from anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;
