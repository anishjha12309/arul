-- Arul — the hand-pinning column, tier 1 of the feed order. Restored 2026-09-02.
--
-- The feed is ONE clause per scope and this column leads it -> the CMS page copies that clause verbatim:
--   feed_rank ASC NULLS LAST -> apply_count/set_count DESC -> created_at DESC -> id ASC
-- NULL means UNPINNED -> the ordinary state of ~every row -> the feed is unchanged until someone pins.
-- Never fold NULL to 0 and never backfill -> 0 is a valid top-most pin -> the absence IS the feature.
-- Imports write no rank -> a bulk drop CANNOT displace the pinned head -> that is the safety property.
-- Curation must never live in `sort_order` -> imports own that column and reset it -> v1 died there silently.
-- No default, no index -> nothing sorts on it in SQL at scale -> the CMS reads a few hundred rows whole.
-- The CMS writes it as a full rewrite per scope per save -> sparse ranks (10, 20, 30 …) -> a reorder never cascades.
-- build-catalog still stamps `feed_rank` into the catalog JSON as a computed POSITION over the new order.
-- Same name, different things -> the column is a sort key, the JSON field is a position -> no app release needed.
alter table wallpapers add column if not exists feed_rank integer;
alter table ringtones  add column if not exists feed_rank integer;
