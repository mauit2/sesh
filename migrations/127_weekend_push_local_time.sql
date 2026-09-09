-- 127: the Friday nudge lands at 16:00 in each person's own time zone.
--
-- Each device reports its IANA zone when it registers for push (the app
-- sends TimeZone.current). The job now runs every hour and, per user, asks
-- whether it is Friday 16:00 where THEY are, using their most recently seen
-- device. No zone yet (older builds) falls back to Europe/Stockholm. Sent
-- once per user per local week.
--
-- Applied 2026-09-09 as weekend_push_local_time.

alter table device_tokens add column if not exists time_zone text;

drop function if exists public.register_device_token(text, text);
create or replace function public.register_device_token(
  p_token text, p_platform text default 'ios', p_time_zone text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_tz text := null;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  -- Keep only a zone Postgres can actually use.
  if p_time_zone is not null then
    begin
      perform now() at time zone p_time_zone;
      v_tz := p_time_zone;
    exception when others then v_tz := null; end;
  end if;
  insert into device_tokens (user_id, token, platform, time_zone, updated_at)
  values (auth.uid(), p_token, p_platform, v_tz, now())
  on conflict (token)
  do update set user_id    = excluded.user_id,
                platform   = excluded.platform,
                time_zone  = coalesce(excluded.time_zone, device_tokens.time_zone),
                updated_at = now();
end $$;
grant execute on function public.register_device_token(text, text, text) to authenticated;

-- One row per person per local week, instead of one per global week.
drop table if exists private.weekend_push_log;
create table private.weekend_push_log (
  user_id uuid not null references profiles(id) on delete cascade,
  week_start date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, week_start)
);

create or replace function private.run_weekend_push()
returns integer language plpgsql security definer set search_path = public, private as $$
declare r record; v_local timestamp; v_week date; v_n integer := 0; v_title text; v_body text;
begin
  for r in
    select p.id,
           coalesce((select t.time_zone from device_tokens t
                      where t.user_id = p.id and t.time_zone is not null
                      order by t.updated_at desc limit 1), 'Europe/Stockholm') as tz
      from profiles p
     where p.weekend_push_opt_in and p.business_id is null
       and exists (select 1 from device_tokens t where t.user_id = p.id)
  loop
    v_local := now() at time zone r.tz;
    if extract(dow from v_local) <> 5 or extract(hour from v_local) <> 16 then continue; end if;
    v_week := date_trunc('week', v_local)::date;
    if exists (select 1 from private.weekend_push_log l where l.user_id = r.id and l.week_start = v_week) then continue; end if;

    case extract(week from v_local)::int % 3
      when 0 then v_title := 'Weekend, then.';
                  v_body  := 'If you''re heading out, keep track of the night in one place. Drinks, stops, who''s live. And a way home.';
      when 1 then v_title := 'Friday''s here';
                  v_body  := 'Whatever tonight looks like, Sejdel keeps the tab so you don''t have to. Water between rounds, taxi after.';
      else        v_title := 'The weekend''s on';
                  v_body  := 'See who''s out, keep count, get home safe. That''s the whole point of it.';
    end case;

    insert into private.weekend_push_log (user_id, week_start) values (r.id, v_week);
    perform private.notify_push(r.id, v_title, v_body, jsonb_build_object('type', 'weekend'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Every hour, every day: somewhere it is always about to be Friday 16:00.
select cron.schedule('weekend-push', '0 * * * *', $$select private.run_weekend_push()$$);
