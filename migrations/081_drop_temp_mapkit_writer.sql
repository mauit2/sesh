-- 081_drop_temp_mapkit_writer.sql — remove the backfill's write channel.
--
-- The Apple Maps backfill (080) needed to post ~750 id pairs into the database.
-- Rather than route that volume through a client, it called a temporary
-- SECURITY DEFINER function guarded by a shared secret. That function is a
-- standing liability once the job is done — anon could call it with a hardcoded
-- secret — so it is dropped the moment the backfill finishes.
drop function if exists apply_mapkit_ids(text, jsonb);

-- Coordinates moved for the curated rows, so the duplicate map is stale.
select refresh_venue_canonical();

notify pgrst, 'reload schema';
