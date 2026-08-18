-- 109: ensure_qr_token and bump_campaign_stats also carried an explicit anon
-- grant (from the project default privilege), not just PUBLIC. Revoke it.
revoke execute on function public.ensure_qr_token(uuid) from anon;
revoke execute on function public.bump_campaign_stats(uuid, integer, integer) from anon;
