# Frozen: the numbered migrations (001–135)

These files are the history of the production database up to 5 November
2026. They are kept for reading, not for applying: 44 changes in
production's migration history never had a file here, and 16 files here
were applied under other names or never applied, so rebuilding a database
from this folder does not give you production's schema.

Database changes now live in `supabase/migrations/` and go through the
Supabase CLI. See `supabase/README.md`.
