# 114–116 — business payments (applied in Supabase, 6 Sep 2026)

Applied through the Supabase MCP without local files; their content is in the
project's migration history (`supabase migration list` / dashboard):

- `20260906113337` business_owner_select_policy — owners (and admins) can read their own `businesses` rows.
- `20260906113556` business_art_policy_qualify_name — the `campaign-art` storage policy qualifies `objects.name`, so an approved owner can upload under `business/<id>/`.
- `20260906113823` business_apple_products — `business_products` (App Store consumables), Apple transaction columns on `business_orders`, `business_mark_paid`, pay-after-approval.

Everything they introduced is superseded or restated by 117–120 below.
