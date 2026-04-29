-- Invites need to remember which mode they were sent from. Without this,
-- a live-mode host firing invites at their saved crew dropped recipients
-- into PLAN mode of the same session — which is the wrong half: the
-- host is logging drinks against the live ledger and the recipient
-- never sees them.
--
-- Adding a `mode` column with a CHECK so callers can't sneak in
-- garbage. Default 'plan' for back-compat with rows inserted before
-- this migration (none in production yet, but cheap insurance).

alter table invites
  add column if not exists mode text not null default 'plan'
    check (mode in ('plan', 'live'));

-- Force PostgREST to reload the schema cache so the new column is
-- visible to clients without a server restart.
notify pgrst, 'reload schema';
