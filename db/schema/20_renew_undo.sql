-- Arul — `pre_renew_published_at`, what makes a CMS Renew undoable.
--
-- A Renew (19_renewed_at.sql) re-stamps published_at = now(), which destroys the debut date. Undo has to
-- put the row back EXACTLY as it was (owner's call, 2026-09-15), so the renew keeps the date it
-- overwrites here, and Undo writes it back and clears both renew columns.
--
-- Written ONLY by the unified CMS feed-order page, in the same UPDATE as the renew:
--   renew: pre_renew_published_at = CASE WHEN renewed_at IS NULL THEN published_at ELSE pre_renew_published_at END
-- -> only the FIRST renew of a chain records it, so renewing an item again and then undoing still returns
--    it to its original debut, never to the previous renew's timestamp.
--   undo:  published_at = coalesce(pre_renew_published_at, published_at), renewed_at = NULL,
--          pre_renew_published_at = NULL
-- 15_published_at.sql's trigger keeps an explicitly written non-null published_at, so the restore survives.
--
-- Never read by the app: build-catalog deletes it from the JSON (a CMS bookkeeping column, not content).
-- Nullable, no default, no index. No backfill here — the one row renewed before this file existed
-- (Bala Murugan, 2026-09-15) was restored by hand from the catalog built before that renew.

alter table wallpapers add column if not exists pre_renew_published_at timestamptz;
alter table ringtones  add column if not exists pre_renew_published_at timestamptz;
