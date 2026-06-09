-- 011_session_ghosts.sql
--
-- Manually-added "ghost" guests now sync across every device in a group
-- session instead of living only on the phone that added them. They ride
-- on the session row as a JSONB array so the existing 3s session poll
-- already distributes them, and they vanish automatically when the
-- session row is deleted / the sesh ends. RLS on `sessions` already
-- restricts who can read/update the row, so no new policy is needed.
--
-- Shape of each element (mirrors the app's GhostMember Codable):
--   { "id": uuid, "name": text, "sex": "male"|"female", "age": int,
--     "weightKg": double, "createdAt": iso8601,
--     "drinks": [ { "id": uuid, "optionName": text, "detail": text,
--                   "category": text, "volumeML": double, "abv": double,
--                   "consumedAt": iso8601 } ] }
alter table sessions
  add column if not exists ghosts jsonb not null default '[]'::jsonb;
