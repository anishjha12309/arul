-- Arul — Neon seed data. Run AFTER every db/schema/*.sql on a fresh database.
-- Only app_config is seeded. Wallpaper and ringtone rows arrive via the
-- content-import pipeline (tools/content-import) or the CMS — content-ops skill.
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
  -- Arul's own sub-site. These were the shared /privacy/ and /terms/ pages until
  -- 2026-08-20, when each app got a self-contained set; the shared privacy slug now
  -- redirects to the website's own policy and no longer describes this app.
  '{
     "privacy": "https://hsrutility.com/arul/privacy-policy/",
     "terms":   "https://hsrutility.com/arul/terms/",
     "refund":  "https://hsrutility.com/arul/refund-policy/"
   }'::jsonb,
  '{}'::jsonb,
  '1.0.0'
)
on conflict (id) do nothing;
