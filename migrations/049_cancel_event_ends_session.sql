-- 049_cancel_event_ends_session.sql
--
-- Cancelling an event whose sesh was already running deleted the event
-- row but left the linked session active_live forever: with the event
-- gone, the lifecycle job no longer saw the session (its end conditions
-- live in the event loop), so members kept getting resumed into a
-- zombie sesh on every app open. Cancel now ends the session first.

create or replace function public.cancel_event(p_event uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_session uuid;
begin
  select e.live_session_id into v_session
    from events e
   where e.id = p_event and e.host_id = auth.uid();

  if v_session is not null then
    update sessions set active_live = false where id = v_session;
  end if;

  delete from events where id = p_event and host_id = auth.uid();
end; $$;
