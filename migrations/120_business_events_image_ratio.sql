-- 120: business events carry their picture's ratio, like posts (Instagram clamp).
-- Applied 2026-09-08 as business_events_image_ratio.
alter table public.business_events add column if not exists image_ratio real not null default 1;
-- business_create_event(uuid, text, timestamptz, text, real) stores it clamped 0.8…1.91;
-- business_events_upcoming(), business_profile() and business_overview() return image_ratio.
