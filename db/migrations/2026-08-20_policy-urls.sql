-- db/seed.sql carries the correct values now, but it ends in
-- `on conflict (id) do nothing`, so re-running it against a live database changes
-- nothing. This is the file that actually moves production.
-- Note on this directory: Arul applies db/schema/*.sql in filename order and then
-- seed.sql, and had no migrations before this. A one-off UPDATE against live data is
-- neither of those things, so it lives here rather than being smuggled into the
-- schema files, where a fresh-database run would replay it for no reason.
-- Idempotent: re-running it is a no-op. Safe to apply before the app release that
-- points at these URLs — the app reads privacy and terms from compiled constants in
-- AppConfig, not from this map.

update app_config
set policy_urls = '{
     "privacy": "https://hsrutility.com/arul/privacy-policy/",
     "terms":   "https://hsrutility.com/arul/terms/",
     "refund":  "https://hsrutility.com/arul/refund-policy/"
   }'::jsonb
where id = 1;

