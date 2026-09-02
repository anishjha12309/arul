-- Arul — Neon seed data; run AFTER every db/schema/*.sql on a fresh database.
-- Only app_config is seeded -> wallpaper and ringtone rows arrive via tools/content-import or the CMS.
-- `prices` is PAYWALL DISPLAY only (paise, INR) -> the debit amount is a constant in workers/src -> change both.

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
  -- Legal pages live on Arul's OWN sub-site -> the shared /privacy/ page no longer describes this app.
  '{
     "privacy": "https://hsrutility.com/arul/privacy-policy/",
     "terms":   "https://hsrutility.com/arul/terms/",
     "refund":  "https://hsrutility.com/arul/refund-policy/"
   }'::jsonb,
  '{}'::jsonb,
  '1.0.0'
)
on conflict (id) do nothing;
