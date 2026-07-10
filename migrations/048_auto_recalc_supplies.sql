-- 048_auto_recalc_supplies.sql
--
-- The calculated list only self-healed on devices with EDIT rights: when
-- the host's phone was closed and someone RSVP'd, every other member was
-- stuck looking at a stale one-person list (amber "being recalculated"
-- banner that nothing ever recalculated). The recalculation is fully
-- deterministic — same inputs on every device — so ANY going member's
-- device may write it through this dedicated RPC. Manual list edits keep
-- going through set_event_supplies with the host/everyone permission.

create or replace function public.auto_recalc_event_supplies(
  p_event uuid, p_supplies jsonb
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set supplies = coalesce(p_supplies, '{}'::jsonb)
   where id = p_event
     and plan_mode = 'calc'
     and exists (
       select 1 from event_members m
       where m.event_id = p_event
         and m.profile_id = auth.uid()
         and m.status = 'going'
     );
end; $$;

revoke execute on function public.auto_recalc_event_supplies(uuid, jsonb) from public;
revoke execute on function public.auto_recalc_event_supplies(uuid, jsonb) from anon;
grant execute on function public.auto_recalc_event_supplies(uuid, jsonb) to authenticated;
