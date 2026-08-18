-- 110: close the arbitrary-session self-join.
--
-- The old INSERT policy on session_members only checked profile_id =
-- auth.uid(), so any authenticated user could POST a membership row for ANY
-- session_id and become a member — bypassing join_session_by_code's join-code
-- + active-session gate and the plan/live mode separation. Membership then
-- unlocks the member-read policies on sessions, session_drinks, session_snaps,
-- session_stops, and the "read session peers" policy on profiles, exposing
-- other users' drinks, snaps, stops, locations, and profile fields.
--
-- The only legitimate CLIENT insert is the host adding themselves to a session
-- they just created (SessionService.create). Every other join path — code,
-- invite accept, event auto-live — runs through SECURITY DEFINER functions
-- that bypass RLS, so they are unaffected by tightening this policy.

drop policy if exists "members: self insert" on public.session_members;

create policy "members: self insert" on public.session_members
  for insert to public
  with check (
    profile_id = auth.uid()
    and exists (
      select 1 from public.sessions s
      where s.id = session_members.session_id
        and s.host_id = auth.uid()
    )
  );
