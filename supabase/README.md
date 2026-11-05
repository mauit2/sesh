# Database: local stack and migrations

Two rules, enforced by code:

1. **Local code never connects to production.** A Debug build of the app
   compiles in `http://127.0.0.1:54321` (the local stack) and does not
   contain the production URL. The scripts under `scripts/` and
   `marketing/` refuse to run unless `SUPA_URL` is set explicitly; the
   GitHub workflow is the one place that names production.
2. **Every database change is a migration file** under
   `supabase/migrations/`, applied locally first, then pushed. Nothing is
   run in the dashboard's SQL editor any more.

## One-time setup (done on this Mac on 5 Nov 2026)

    brew install supabase/tap/supabase docker colima
    colima start --cpu 2 --memory 4 --disk 30     # container runtime, no GUI
    supabase init                                 # wrote supabase/config.toml

## One-time: take production's schema as the baseline (done 5 Nov 2026)

The old `migrations/` folder does not reproduce production (see its
README), so the baseline was taken from production itself:

    supabase login                                # opens the browser once
    supabase link --project-ref lltuozmbxacxiepardys
    supabase db dump --remote --schema public,private \
      -f supabase/migrations/20261105150457_baseline.sql

(`db pull` was tried first and reported nothing to pull, because it diffs
against production's own migration history rather than its schema.) The
dump covers tables, functions, policies, triggers and indexes in `public`
and `private`. Two files around it cover what a dump leaves out:

- `20261105150000_extensions.sql` – pgcrypto, uuid-ossp, pg_net, pg_cron,
  http, and the `private` schema, so the baseline has them to lean on.
- `20261105150500_environment.sql` – the six storage buckets, the policies
  on `storage.objects`, and the seven `cron.schedule` jobs, copied from
  production. Idempotent, so it is harmless to re-run anywhere.

Production's history table still lists the 158 old versions. Make it
match the folder once, from the repo root (the CLI is already linked):

    scripts/repair-migration-history.sh

That edits only the bookkeeping table `supabase_migrations.schema_migrations`
on production: the 158 old versions become "reverted", the three files
become "applied". No schema or data changes. Afterwards
`supabase migration list` shows three rows present on both sides and
`supabase db push` reports nothing to do.

## Every day

    colima start                  # if the Mac was rebooted
    supabase start                # API on :54321, Postgres on :54322, Studio on :54323
    supabase db reset             # rebuild the local DB from migrations + seed.sql
    supabase status               # URLs and keys; Mailpit (sign-up emails) on :54324

Run the app in the simulator with the normal **sesh.app** scheme. It is a
Debug build, so it talks to the local stack. Sign up with any address; the
confirmation code arrives in Mailpit at http://127.0.0.1:54324 (the API
`http://127.0.0.1:54324/api/v1/messages` lists it as JSON). A `db reset`
wipes accounts, so just sign up again. The throwaway account used for the
first check on 5 Nov 2026 was local-test@example.com / LocalDev1! with
username localtest; it exists only on this Mac. The database can be read
without installing psql:

    docker exec supabase_db_sesh.app psql -U postgres -d postgres -c "select count(*) from public.profiles"

The maps
have bars on them because `supabase/seeds/venues.sql` is applied by
`db reset` (7,672 venues, prices and the sun profiles of ten cities, all
public data, no people). Regenerate it when the venue data has moved on:

    SUPA_URL=https://lltuozmbxacxiepardys.supabase.co SUPA_ANON=<anon key> node scripts/seed-venues.mjs

## Looking at production on purpose

The one deliberate exception to rule 1 is the **sesh.app (PRODUCTION)**
scheme in Xcode's scheme picker. It runs the same Debug build with the
production URL and key set as environment variables, and the app shows a
red PRODUCTION DATA badge at the top of every screen while it runs. Use it
to review reports as admin or to look at real data; never for trying
things out.

To run a Debug build on a physical phone, the simulator's loopback address
will not reach the Mac: in the Xcode scheme, set the environment variable
`SEJDEL_SUPABASE_URL` to `http://<your Mac's LAN IP>:54321`.

## Making a database change

    supabase migration new <short_name>           # creates supabase/migrations/<ts>_<short_name>.sql
    # write the SQL in that file
    supabase db reset                             # proves it applies cleanly from scratch
    # test in the app, commit the file with the code that needs it
    supabase db push                              # applies only the new file(s) to production

`db push` is the only route to production. It asks for confirmation and
refuses if the migration history has diverged, which is the point.

## What lives where

- `supabase/config.toml`: local stack settings. Auth confirmations are on
  with an 8-digit code, like production, so the app's sign-up flow is the
  real one.
- `supabase/seed.sql`: local-only rows (the push config is set to no URL
  so no local run ever tries to send a push).
- `supabase/functions/`: the edge functions, served locally by
  `supabase start` and deployed with `supabase functions deploy <name>`.
- `migrations/`: frozen history, read-only.
