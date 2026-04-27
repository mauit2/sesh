-- Adds a `live` flag to session_drinks so Live Sesh and the regular
-- (manual / duration-slider) calculator can keep their drinks in
-- separate ledgers within the same group session.
--
-- - live = false: drinks added from the regular session view; show up
--   in the OrderCard, feed the manual-duration BAC calculation.
-- - live = true:  drinks added from Live Sesh mode; show up only in
--   the live timeline + roster, feed the per-drink Widmark BAC.
--
-- Existing rows default to false (i.e. "regular" drinks) which keeps
-- prior history visible in the regular calculator.

ALTER TABLE session_drinks
  ADD COLUMN IF NOT EXISTS live BOOLEAN NOT NULL DEFAULT false;

-- Index for the common filter shape: "live drinks for this session".
CREATE INDEX IF NOT EXISTS session_drinks_live_idx
  ON session_drinks (session_id, live);
