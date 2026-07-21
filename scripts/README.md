# scripts

One-off maintenance scripts. Not part of the iOS build.

## reprocess-images.mjs

Cleans up images uploaded **before** the egress fixes: shrinks oversized
originals in place, generates the `_thumb` siblings the app now fetches for
small views, and stamps a 1-year `Cache-Control` on everything. Idempotent and
safe to re-run.

### Run it

```bash
cd scripts
npm install                     # once — installs @supabase/supabase-js + sharp

# Preview what it would do (no writes):
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key> node reprocess-images.mjs --dry-run

# Do it for real:
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key> node reprocess-images.mjs

# Or just one bucket:
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key> node reprocess-images.mjs --bucket=avatars
```

Get the `service_role` key from **Supabase → Project Settings → API → service_role**.

### Notes

- The key is read from the environment and is **never** written to disk or
  committed. Don't paste it into any file.
- Uses the **service_role** key because it needs to read + overwrite every
  user's objects (bypasses RLS). Run it locally only; never ship it.
- Re-running is harmless: already-small originals are left byte-for-byte
  intact, existing thumbnails are skipped.
- Buckets processed: `avatars` (shrunk to 256px, no thumb), `recap-photos`,
  `session-snaps`, `event-covers`, `stories` (shrunk + 512px thumb).
