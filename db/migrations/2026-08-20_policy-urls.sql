-- Arul — point app_config.policy_urls at Arul's own sub-site, on an ALREADY SEEDED
-- database.
--
-- db/seed.sql carries the correct values now, but it ends in
-- `on conflict (id) do nothing`, so re-running it against a live database changes
-- nothing. This is the file that actually moves production.
--
-- Until 2026-08-20 privacy and terms were the SHARED hsrutility.com/privacy/ and
-- /terms/ pages, one pair of documents covering both this app and Pakiza. The site
-- now gives each app a self-contained sub-site: the shared privacy slug still
-- resolves (it redirects to the website's own policy) but no longer describes this
-- app. Refund is new — the apps had no published refund page before. There is no
-- copyright entry: no copyright policy is published, and a link to a 404 is worse
-- than an absent one.
--
-- Note on this directory: Arul applies db/schema/*.sql in filename order and then
-- seed.sql, and had no migrations before this. A one-off UPDATE against live data is
-- neither of those things, so it lives here rather than being smuggled into the
-- schema files, where a fresh-database run would replay it for no reason.
--
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

-- The catalog Worker serves app_config.json from KV, rebuilt by the build-catalog
-- cron. Until that next runs, clients keep the old snapshot.
