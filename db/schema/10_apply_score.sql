-- Arul — Neon Postgres schema (merit ranking). Apply after 09_meta_anon_id.sql.
--
-- The decaying half of the popularity signal. `apply_count` (06_popularity.sql)
-- stays exactly as it was — lifetime applies, shown in the CMS, never a sort key
-- again: a number that only rises freezes the head of the feed forever, because
-- the row at slot 1 earns applies partly BECAUSE it is at slot 1 and nothing
-- below it can arithmetically catch up. These columns are the same event stream
-- weighted by recency, so a row that stops earning applies falls on its own.
-- The full contract, both terms of the score and why the newcomer credit is
-- stepped: workers/src/lib/feed-score.ts.
--
-- ZERO ADDED COST, AND THAT IS WHY IT IS SHAPED THIS WAY. There is no events
-- table and no per-view write: `apply_score` is decayed-and-incremented inside
-- the SAME single UPDATE that already bumps apply_count in /media/signed-url —
-- no extra statement, no extra round trip, no new rows. Ranking itself writes
-- NOTHING: build-catalog computes the order in memory and emits it in the
-- catalog JSON. Logging apply events instead would have been the version that
-- costs real money.
--
-- `scored_at` IS PART OF THE VALUE, not metadata. `apply_score` was last decayed
-- at that instant, so two rows both holding 5.0 are NOT equal if one was applied
-- yesterday and the other in March. Never ORDER BY or compare apply_score in
-- SQL — every reader decays it to a common instant first (decayedUses()).
-- Nullable with no default because null means "never applied", which scores 0;
-- folding it to now() would score every untouched row as freshly applied.
--
-- double precision, not numeric: this is a sort key, not money, and the decay is
-- a pow() either way. No index — build-catalog full-scans the published rows it
-- already reads, and nothing sorts on these in SQL.
alter table wallpapers add column if not exists apply_score double precision not null default 0;
alter table wallpapers add column if not exists scored_at   timestamptz;
alter table ringtones  add column if not exists set_score   double precision not null default 0;
alter table ringtones  add column if not exists scored_at   timestamptz;

-- Seed from the lifetime counters, ONCE. Starting everyone at 0 would discard
-- every apply ever made and reset the feed to newest-first on the day this
-- ships; seeding treats the existing history as if it had happened today, so
-- current favourites keep their standing and decay forward from here (owner's
-- call, 2026-08-25). Guarded on scored_at IS NULL so a re-apply of this file
-- cannot re-seed a row that has since been decayed by real traffic.
update wallpapers set apply_score = apply_count, scored_at = now()
  where apply_count > 0 and scored_at is null;
update ringtones  set set_score   = set_count,   scored_at = now()
  where set_count   > 0 and scored_at is null;
