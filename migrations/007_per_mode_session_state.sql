-- Per-mode session state: plan and live are now independent, even when
-- they happen to track the same `sessions` row.
--
-- Background. Up to now, `sessions.active` was a single global boolean
-- and `session_members` had one row per (session, profile). When the
-- host of a mirrored group ended in plan, flipping `active = false`
-- killed the live experience too — even though everyone explicitly
-- wants plan and live to be separate modes. Same problem on leave: a
-- user who'd mirrored couldn't leave plan without dropping out of
-- live, because both modes shared a single session_members row.
--
-- Fix. Two independent "is this session still going for me in this
-- mode?" axes:
--
--   sessions:          active_plan,  active_live   — host-end state
--   session_members:   in_plan,      in_live       — per-user, per-mode
--                                                    membership flags
--
-- Both default to TRUE so existing rows behave as "in both modes",
-- which matches legacy semantics (everyone who was in a session
-- before this migration was effectively in both modes of it).
--
-- Reads filter by the relevant flag for the mode being shown:
--   * Plan store fetches members where in_plan = true.
--   * Live store fetches members where in_live = true.
--   * "Has the host ended this session in my mode?" = active_<mode> false.
--
-- The legacy `sessions.active` column is left in place, untouched. It
-- stays TRUE forever from now on (the per-mode flags carry the new
-- semantics). Older queries that still read it just see a permanently-
-- alive flag, which is harmless — they'll eventually be dropped or
-- migrated.

-- ---------------------------------------------------------------------------
-- 1. Per-mode columns
-- ---------------------------------------------------------------------------

alter table sessions
  add column if not exists active_plan boolean not null default true,
  add column if not exists active_live boolean not null default true;

alter table session_members
  add column if not exists in_plan boolean not null default true,
  add column if not exists in_live boolean not null default true;

-- Index the common filter shape: "members of this session who are
-- still in plan / live mode". Two tiny indexes; the planner will use
-- the relevant one per scope query.
create index if not exists session_members_session_in_plan_idx
  on session_members (session_id) where in_plan;
create index if not exists session_members_session_in_live_idx
  on session_members (session_id) where in_live;

-- ---------------------------------------------------------------------------
-- 2. RLS: members must be able to UPDATE their own row's in_* flags.
--    Leaving a mode is now an UPDATE (flip in_<mode> false), not a
--    DELETE — the row stays so the OTHER mode can keep using it. Read
--    + insert policies are assumed to already exist; we only add the
--    update path here.
-- ---------------------------------------------------------------------------

alter table session_members enable row level security;

drop policy if exists session_members_update_own on session_members;
create policy session_members_update_own
  on session_members for update
  to authenticated
  using       ( profile_id = auth.uid() )
  with check  ( profile_id = auth.uid() );

-- The host needs to be able to flip active_plan / active_live on their
-- own session row. The existing UPDATE policy on `sessions` should
-- already cover host-as-owner, but install a canonical one defensively
-- so this migration is self-sufficient.

alter table sessions enable row level security;

drop policy if exists sessions_update_host on sessions;
create policy sessions_update_host
  on sessions for update
  to authenticated
  using       ( host_id = auth.uid() )
  with check  ( host_id = auth.uid() );

-- ---------------------------------------------------------------------------
-- 3. Replace the join RPC. New signature takes a `mode` parameter so we
--    know which `in_<mode>` flag to set when upserting the membership
--    row. The merge semantics (`x OR existing.x`) are important: a
--    user who's already in live and now joins in plan should end up
--    in_plan = TRUE, in_live = TRUE — not in_live = FALSE (which
--    would silently kick them out of live).
-- ---------------------------------------------------------------------------

drop function if exists join_session_by_code(text);
drop function if exists public.join_session_by_code(text);

create or replace function join_session_by_code(code text, mode text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  uid uuid := auth.uid();
  joining_plan boolean := mode = 'plan';
  joining_live boolean := mode = 'live';
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if mode not in ('plan', 'live') then
    raise exception 'invalid mode: %', mode;
  end if;

  -- Find a session that's still active in the requested mode. If the
  -- host already ended it for this mode, the join fails — they'd
  -- otherwise land in a dead group. The OTHER mode's state is
  -- irrelevant for the join check.
  select id into sid from sessions
    where join_code = upper(code)
      and ((joining_plan and active_plan) or (joining_live and active_live))
    limit 1;

  if sid is null then
    raise exception 'no active session for code % in % mode', code, mode;
  end if;

  -- Upsert the membership row, OR-merging the in_* flag we're setting
  -- so a cross-mode join doesn't clobber an existing membership in
  -- the other mode.
  insert into session_members (session_id, profile_id, in_plan, in_live)
  values (sid, uid, joining_plan, joining_live)
  on conflict (session_id, profile_id) do update
    set in_plan = session_members.in_plan or excluded.in_plan,
        in_live = session_members.in_live or excluded.in_live;

  return sid;
end;
$$;

grant execute on function join_session_by_code(text, text) to authenticated;
