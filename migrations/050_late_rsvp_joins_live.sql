-- 050_late_rsvp_joins_live.sql
--
-- Accepting an event invite AFTER the event already went live left the
-- late guest stranded: they became a going event member, but only the
-- lifecycle's START pass inserts session members — so the running group
-- sesh never included them. respond_to_event now enrolls a late "going"
-- straight into the linked session (in_live), and the client's existing
-- resume path pulls them into the sesh on its next poll.

create or replace function public.respond_to_event(
  p_event uuid, p_status text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_session uuid;
begin
  if p_status not in ('going', 'declined') then
    raise exception 'invalid status';
  end if;

  update event_members
     set status = p_status, responded_at = now()
   where event_id = p_event and profile_id = auth.uid();

  if p_status = 'going' then
    select e.live_session_id into v_session
      from events e
     where e.id = p_event
       and e.live_session_id is not null
       and e.live_ended_at is null;

    if v_session is not null
       and exists (select 1 from sessions s where s.id = v_session and s.active_live) then
      insert into session_members (session_id, profile_id, in_plan, in_live)
      select v_session, auth.uid(), false, true
      where not exists (
        select 1 from session_members m
        where m.session_id = v_session and m.profile_id = auth.uid()
      );
    end if;
  end if;
end; $$;
