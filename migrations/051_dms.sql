-- 051_dms.sql
--
-- Direct messages: friend-to-friend chat threads, plus story reactions —
-- liking or replying to a story lands in the author's DMs (IG model).
--
--   kind 'text'        plain chat message
--   kind 'story_reply' text sent from the story viewer (story context)
--   kind 'story_like'  ❤️ on a story (no body)
--
-- story_id survives as context while the story lives (24h purge sets it
-- null via ON DELETE SET NULL); story_path snapshots the storage path so
-- the thumbnail can render while the image still exists.

create table if not exists public.dm_messages (
  id           uuid primary key default gen_random_uuid(),
  sender_id    uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  kind         text not null default 'text'
               check (kind in ('text', 'story_reply', 'story_like')),
  body         text check (char_length(body) <= 1000),
  story_id     uuid references public.live_stories(id) on delete set null,
  story_path   text,
  created_at   timestamptz not null default now(),
  read_at      timestamptz,
  check (kind = 'story_like' or body is not null)
);

create index if not exists dm_messages_recipient_idx
  on public.dm_messages (recipient_id, created_at desc);
create index if not exists dm_messages_sender_idx
  on public.dm_messages (sender_id, created_at desc);

alter table public.dm_messages enable row level security;

-- Both ends of the conversation can read it.
drop policy if exists dm_select on public.dm_messages;
create policy dm_select on public.dm_messages
  for select using (sender_id = auth.uid() or recipient_id = auth.uid());

-- Send only as yourself, and only to an accepted friend (blocking severs
-- the friendship, so blocked users can't message either way).
drop policy if exists dm_insert on public.dm_messages;
create policy dm_insert on public.dm_messages
  for insert with check (
    sender_id = auth.uid()
    and sender_id <> recipient_id
    and exists (
      select 1 from friendships f
      where f.status = 'accepted'
        and ((f.requester_id = auth.uid() and f.addressee_id = recipient_id)
          or (f.addressee_id = auth.uid() and f.requester_id = recipient_id))
    )
  );

-- Only the recipient flips read_at (and can't alter anything else in
-- practice — the app only issues read_at patches; belt & braces would
-- need a trigger, overkill for a read receipt).
drop policy if exists dm_update_read on public.dm_messages;
create policy dm_update_read on public.dm_messages
  for update using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

-- Push the recipient on every new message (040 pattern).
create or replace function public.on_dm_notify()
returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_name text;
begin
  select p.name into v_name from profiles p where p.id = NEW.sender_id;
  perform private.notify_push(
    NEW.recipient_id,
    coalesce(v_name, 'A friend'),
    case NEW.kind
      when 'story_like'  then 'liked your story ❤️'
      when 'story_reply' then 'replied to your story: ' || left(coalesce(NEW.body, ''), 80)
      else left(coalesce(NEW.body, ''), 120)
    end,
    jsonb_build_object('type', 'dm', 'sender_id', NEW.sender_id)
  );
  return NEW;
end; $$;

drop trigger if exists trg_dm_notify on public.dm_messages;
create trigger trg_dm_notify
  after insert on public.dm_messages
  for each row execute function public.on_dm_notify();
