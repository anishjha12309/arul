-- Arul — `renewed_at`, the operator's Renew stamp: tier 1 of the New chip.
--
-- The New chip is three tiers, all inside the same 7-day window (docs/browse.md):
--   1. renewed_at in the window, most recent renew first — a stack, the last one placed on top;
--   2. published_at in the window, newest debut first;
--   3. filler up to 20, by uses.
-- Renewing is how an operator puts an old wallpaper or ringtone back on top of New by hand.
--
-- ONE writer: the unified CMS feed-order page (POST …/feed-order[/ringtones]/renew/:id). It sets this
-- AND re-stamps published_at = now() in the same UPDATE, in the same transaction as the
-- content_version bump. Deliberately NOT a trigger: a renew is an operator act, never a side effect of
-- publishing — flipping is_published back on must not resurface anything (15_published_at.sql).
--
-- Why published_at is re-stamped too (owner's call, overwriting the debut date): builds before
-- 1.0.0+78 do not know this column, and published_at is the only thing their New chip reads -> the
-- renewed row still reaches New there, in their old order. 15_published_at.sql's trigger keeps an
-- explicitly supplied non-null value, so the re-stamp survives it.
--
-- Unpublishing does NOT clear it: a row renewed, pulled and put back inside the 7 days returns to tier 1.
--
-- Nullable, no default, NO backfill: null means never renewed, the ordinary state.
-- No index: nothing server-side filters or sorts on it — build-catalog's SELECT * carries it into the
-- JSON and the app windows it client-side, exactly like published_at.

alter table wallpapers add column if not exists renewed_at timestamptz;
alter table ringtones  add column if not exists renewed_at timestamptz;
