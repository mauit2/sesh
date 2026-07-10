-- 042_events.sql
--
-- PLAN tab → Events: plan a party / trip / pregame ahead of time, invite
-- friends (RSVP), and store the provisioning calculator's inputs/outputs
-- (target tier, drinking window, nights, container counts) so every
-- attendee sees the same shopping list.
--
-- Patterns reused:
--  * per-row RSVP membership like invites (008/038): UNIQUE pair,
--    re-invite resets status to 'pending'
--  * ghosts as a JSONB column owned by an RPC (011/015)
--  * SECURITY DEFINER RPCs for all writes (018)
--  * push fan-out through private.notify_push triggers (028/040)

-- ─── tables ────────────────────────────────────────────────────────────

create table if not exists public.events (
  id             uuid primary key default gen_random_uuid(),
  host_id        uuid not null references auth.users(id) on delete cascade,
  title          text not null check (char_length(title) between 1 and 80),
  kind           text not null default 'party'
                 check (kind in ('party', 'trip', 'pregame', 'other')),
  starts_at      timestamptz not null,
  duration_hours numeric not null default 6 check (duration_hours between 1 and 24),
  nights         integer not null default 1 check (nights between 1 and 14),
  -- Target tier as a BAC value. Hard-capped well below the danger tier
  -- (0.15): the calculator must never help someone plan a blackout.
  target_bac     numeric not null default 0.08 check (target_bac between 0.01 and 0.12),
  -- Shopping list: {"beerCan": 24, "wineBottle": 3, ...} keyed by the
  -- client's SupplyContainer raw values.
  supplies       jsonb not null default '{}'::jsonb,
  -- Off-app guests, same GhostMember shape the session ghosts use (011).
  ghosts         jsonb not null default '[]'::jsonb,
  created_at     timestamptz not null default now()
);

create table if not exists public.event_members (
  event_id     uuid not null references public.events(id) on delete cascade,
  profile_id   uuid not null references auth.users(id) on delete cascade,
  status       text not null default 'pending'
               check (status in ('pending', 'going', 'declined')),
  invited_by   uuid references auth.users(id),
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  primary key (event_id, profile_id)
);

create index if not exists event_members_profile_idx
  on public.event_members (profile_id, status);

-- ─── RLS ───────────────────────────────────────────────────────────────

alter table public.events enable row level security;
alter table public.event_members enable row level security;

-- SECURITY DEFINER membership probe so the events/event_members policies
-- never recurse into themselves (same trick as sessions).
create or replace function private.is_event_member(p_event uuid, p_user uuid)
returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from event_members m
    where m.event_id = p_event and m.profile_id = p_user
  );
$$;

drop policy if exists events_select on public.events;
create policy events_select on public.events
  for select using (
    host_id = auth.uid() or private.is_event_member(id, auth.uid())
  );

drop policy if exists event_members_select on public.event_members;
create policy event_members_select on public.event_members
  for select using (
    profile_id = auth.uid()
    or private.is_event_member(event_id, auth.uid())
  );

-- All writes go through the RPCs below — no direct insert/update/delete.

-- ─── RPCs ──────────────────────────────────────────────────────────────

create or replace function public.create_event(
  p_title text, p_kind text, p_starts_at timestamptz,
  p_duration_hours numeric, p_nights integer, p_target_bac numeric
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  insert into events (host_id, title, kind, starts_at, duration_hours, nights, target_bac)
  values (auth.uid(), p_title, p_kind, p_starts_at, p_duration_hours,
          coalesce(p_nights, 1), coalesce(p_target_bac, 0.08))
  returning id into v_id;

  insert into event_members (event_id, profile_id, status, responded_at)
  values (v_id, auth.uid(), 'going', now());

  return v_id;
end; $$;

create or replace function public.invite_to_event(
  p_event uuid, p_recipients uuid[]
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_recipient uuid;
begin
  if not exists (select 1 from events e where e.id = p_event and e.host_id = auth.uid()) then
    raise exception 'only the host can invite';
  end if;

  foreach v_recipient in array p_recipients loop
    -- Only friends can be invited (mirrors send_friend_request's block
    -- guard in 041 — blocks sever friendships, so this also blocks).
    if exists (
      select 1 from friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = v_recipient)
          or (f.addressee_id = auth.uid() and f.requester_id = v_recipient))
    ) then
      insert into event_members (event_id, profile_id, status, invited_by)
      values (p_event, v_recipient, 'pending', auth.uid())
      on conflict (event_id, profile_id) do update
        set status = case
              -- Re-invite wakes a decline back to pending; never demotes
              -- someone already going (038's re-invite lesson).
              when event_members.status = 'declined' then 'pending'
              else event_members.status
            end,
            invited_by = excluded.invited_by;
    end if;
  end loop;
end; $$;

create or replace function public.respond_to_event(
  p_event uuid, p_status text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('going', 'declined') then
    raise exception 'invalid status';
  end if;
  update event_members
     set status = p_status, responded_at = now()
   where event_id = p_event and profile_id = auth.uid();
end; $$;

create or replace function public.leave_event(p_event uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from event_members
   where event_id = p_event and profile_id = auth.uid()
     -- The host can't leave their own event; they cancel it instead.
     and not exists (select 1 from events e where e.id = p_event and e.host_id = auth.uid());
end; $$;

create or replace function public.cancel_event(p_event uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from events where id = p_event and host_id = auth.uid();
end; $$;

create or replace function public.set_event_supplies(p_event uuid, p_supplies jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set supplies = coalesce(p_supplies, '{}'::jsonb)
   where id = p_event and host_id = auth.uid();
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
   where id = p_event and host_id = auth.uid();
end; $$;

create or replace function public.set_event_ghosts(p_event uuid, p_ghosts jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update events
     set ghosts = coalesce(p_ghosts, '[]'::jsonb)
   where id = p_event and host_id = auth.uid();
end; $$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'create_event(text,text,timestamptz,numeric,integer,numeric)',
    'invite_to_event(uuid,uuid[])',
    'respond_to_event(uuid,text)',
    'leave_event(uuid)',
    'cancel_event(uuid)',
    'set_event_supplies(uuid,jsonb)',
    'update_event_plan(uuid,numeric,numeric,integer)',
    'set_event_ghosts(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function public.%s from public', fn);
    execute format('revoke execute on function public.%s from anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;

-- ─── push notifications (040 pattern) ──────────────────────────────────

create or replace function public.on_event_invite_notify()
returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_host text;
  v_title text;
begin
  -- Only fresh invites, not the host's own auto-membership.
  if NEW.status <> 'pending' or NEW.invited_by is null then
    return NEW;
  end if;
  select p.name into v_host from profiles p where p.id = NEW.invited_by;
  select e.title into v_title from events e where e.id = NEW.event_id;
  perform private.notify_push(
    NEW.profile_id,
    '🎉 ' || coalesce(v_host, 'A friend') || ' invited you',
    coalesce(v_title, 'A new event') || ' — open PLAN to RSVP.',
    jsonb_build_object('type', 'event_invite', 'event_id', NEW.event_id)
  );
  return NEW;
end; $$;

drop trigger if exists trg_event_invite_notify on public.event_members;
create trigger trg_event_invite_notify
  after insert on public.event_members
  for each row execute function public.on_event_invite_notify();

create or replace function public.on_event_rsvp_notify()
returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_name text;
  v_title text;
  v_host uuid;
begin
  if NEW.status = OLD.status or NEW.status = 'pending' then
    return NEW;
  end if;
  select e.host_id, e.title into v_host, v_title from events e where e.id = NEW.event_id;
  if v_host is null or v_host = NEW.profile_id then
    return NEW;
  end if;
  select p.name into v_name from profiles p where p.id = NEW.profile_id;
  perform private.notify_push(
    v_host,
    coalesce(v_name, 'Someone') || case when NEW.status = 'going'
      then ' is going 🎉' else ' can''t make it' end,
    coalesce(v_title, 'Your event'),
    jsonb_build_object('type', 'event_rsvp', 'event_id', NEW.event_id)
  );
  return NEW;
end; $$;

drop trigger if exists trg_event_rsvp_notify on public.event_members;
create trigger trg_event_rsvp_notify
  after update on public.event_members
  for each row execute function public.on_event_rsvp_notify();
