-- 094 — let signed-in users report that a bar has outdoor seating.
--
-- The import gave every venue a true/false from billigol.se; this is the
-- crowd's way to correct a false or flag a new bar. Reports only ever SET the
-- flag — there is deliberately no "report that a terrace does not exist",
-- because a single spiteful tap shouldn't be able to delist a bar the import
-- verified. If a terrace closes for good, that's an admin edit.
--
-- Setting the flag bumps venues.updated_at via the 088 trigger, so every
-- client's incremental catalog sync picks the change up on its own.

create or replace function public.report_outdoor_seating(p_venue uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'auth_required'; end if;
  -- Same limiter the web endpoints use, keyed by user rather than IP.
  if not rate_limit_hit('outdoor_report', v_uid::text, 30, '1 hour') then
    raise exception 'rate_limited';
  end if;
  if not exists (select 1 from venues where id = p_venue) then
    raise exception 'venue_not_found';
  end if;

  update venues
     set outdoor_seating            = true,
         outdoor_seating_source     = 'user',
         outdoor_seating_updated_at = now()
   where id = p_venue
     and outdoor_seating is distinct from true;  -- no-op if already true
end $$;

revoke all on function public.report_outdoor_seating(uuid) from public;
grant execute on function public.report_outdoor_seating(uuid) to authenticated;
