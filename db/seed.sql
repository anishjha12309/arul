-- Arul — Neon seed data. Run AFTER db/schema/01→03 on a fresh database.
-- Only app_config is seeded; content rows arrive via the Phase-3 import (content-ops skill).
--
-- prices = PAYWALL DISPLAY values (paise, INR) served via catalog/app_config.json.
-- The Worker's actual debit amount is a constant in workers/src (₹199 = 19900) —
-- keep the two in sync when changing price.

insert into app_config (
  id,
  content_version,
  prices,
  support_email,
  policy_urls,
  feature_flags,
  min_supported_version
)
values (
  1,
  0,
  '{ "monthly": { "amount": 19900, "currency": "INR" } }'::jsonb,
  'support@hsrutility.com',
  '{ "privacy": "https://hsrapps.com/arul/privacy-policy/" }'::jsonb,
  '{}'::jsonb,
  '1.0.0'
)
on conflict (id) do nothing;
