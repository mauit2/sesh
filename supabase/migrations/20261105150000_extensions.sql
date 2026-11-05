-- Runs before the baseline: the dumped functions call net.http_post,
-- pg_cron and the http extension, and columns default to gen_random_uuid.
-- Hosted projects have these on already; a fresh local database does not.
create extension if not exists pgcrypto   with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_net     with schema extensions;
create extension if not exists pg_cron;
create extension if not exists http       with schema extensions;
create schema if not exists private;
