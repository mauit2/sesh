-- 118: Business runs one deal at a time; Business+ several (admin-tunable).
-- Applied 2026-09-08 as business_deal_limits_by_tier.
insert into public.business_limits (key, value, label) values
  ('max_live_campaigns_basic', 1, 'Live deals at once · Business'),
  ('max_live_campaigns', 5, 'Live deals at once · Business+')
on conflict (key) do update set value = excluded.value, label = excluded.label;
-- business_create_deal(): v_max := case when tier = 'plus'
--   then biz_limit('max_live_campaigns') else biz_limit('max_live_campaigns_basic') end
