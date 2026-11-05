-- 135: pushes leave the caller's transaction.
--
-- private.notify_push used to do its work inside whatever statement
-- called it: read push_config, run private.unseen_count (four COUNTs) for
-- the recipient's badge, and queue the HTTP request. Posting a recap, a
-- story or going live fires it once per friend from an AFTER INSERT
-- trigger, so a user with forty friends paid ~200 queries before their
-- insert returned. A business event pays once per follower; an
-- announcement once per user.
--
-- Now notify_push only appends a row to private.push_outbox. A cron job
-- every 15 seconds drains the outbox: badge count, HTTP call, mark sent.
-- Every caller keeps the same signature; nothing else changes. A push
-- arrives up to 15 s later than before, which no notification here needs.

create table if not exists private.push_outbox (
  id          bigserial primary key,
  user_id     uuid not null,
  title       text not null,
  body        text not null,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index if not exists push_outbox_pending_idx on private.push_outbox (id) where sent_at is null;

create or replace function private.notify_push(p_user uuid, p_title text, p_body text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  if p_user is null then return; end if;
  insert into private.push_outbox (user_id, title, body, data)
  values (p_user, coalesce(p_title, ''), coalesce(p_body, ''), coalesce(p_data, '{}'::jsonb));
exception when others then
  return;
end $$;

create or replace function private.run_push_outbox()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare cfg private.push_config; r record; n integer := 0;
begin
  select * into cfg from private.push_config where id = 1;
  if cfg.function_url is null then return 0; end if;
  for r in
    select * from private.push_outbox
     where sent_at is null
     order by id
     limit 500
     for update skip locked
  loop
    begin
      perform net.http_post(
        url     := cfg.function_url,
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'Authorization', 'Bearer ' || cfg.secret),
        body    := jsonb_build_object(
                     'user_id', r.user_id, 'title', r.title, 'body', r.body, 'data', r.data,
                     'badge', private.unseen_count(r.user_id))
      );
      update private.push_outbox set sent_at = now() where id = r.id;
      n := n + 1;
    exception when others then
      -- Leave the row pending; the next run retries it.
      null;
    end;
  end loop;
  -- Sent rows are only an audit trail; a week is plenty.
  delete from private.push_outbox where sent_at < now() - interval '7 days';
  -- pg_cron logs every run; at four runs a minute that is 5,760 rows a day
  -- (the minute-cadence jobs already add 2,880). Keep two days.
  delete from cron.job_run_details where end_time < now() - interval '2 days';
  return n;
end $$;

-- cron.schedule by name replaces an existing job of that name.
select cron.schedule('push-outbox', '15 seconds', $$select private.run_push_outbox()$$);
