-- Arul — lifetime popularity counters; these ARE the feed's sort key.
--
-- The sort key -> build-catalog orders count DESC, created_at DESC, id ASC -> the same clause on every chip.
-- A counter only rises -> slot 1 earns applies because it IS slot 1 -> the sticky head is an accepted cost.
-- Pins and a decayed score were both tried and removed -> never add a second sort key beside the counter.
-- `not null default 0` is load-bearing -> at zero data every row ties -> the sort collapses to newest-first.
--
-- What the number MEANS, precisely — it is not "successful applies":
--   · Bumped in /media/signed-url after the entitlement check -> only PREMIUM users move it.
--   · A blocked free user 403s -> the intent lands in analytics as apply_blocked_premium -> never in this counter.
--   · Counts a URL GRANT, not a confirmed apply -> the OS chooser can still be cancelled -> no confirm round trip.
--   · Shares are excluded: the request carries `action` and only 'apply' counts -> every ringtone grant is a set.
--   · A request with no `action` counts for neither -> pre-change builds cannot pollute the number.
--
-- No index, on purpose -> build-catalog full-scans every published row -> a btree on the counter buys nothing.
alter table wallpapers add column if not exists apply_count bigint not null default 0;
alter table ringtones  add column if not exists set_count   bigint not null default 0;
