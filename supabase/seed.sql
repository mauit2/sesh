-- Local-only seed, applied by `supabase db reset` after the migrations.
-- Nothing here ever reaches production.

-- The push pipeline reads a function URL and a shared secret from
-- private.push_config (both NOT NULL). Locally the URL points at the
-- send-push function on this stack, addressed by its Docker container name
-- so Postgres can reach it from inside the Supabase network. There is no
-- APNs key locally, so the function answers with an error and the outbox
-- row is marked failed; nothing leaves the machine. Guarded so the seed
-- also runs on a stack that has no migrations yet.
do $$
begin
  if to_regclass('private.push_config') is not null then
    insert into private.push_config (id, function_url, secret)
    values (1, 'http://supabase_kong_sesh.app:8000/functions/v1/send-push', 'local-dev')
    on conflict (id) do update
      set function_url = excluded.function_url, secret = excluded.secret;
  end if;
end $$;
