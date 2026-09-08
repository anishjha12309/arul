# Crons — the three triggers and the cold-connection hazard

Read before adding, splitting or "simplifying" a scheduled handler. Declared in
`workers/wrangler.toml [triggers]` as `crons = ["0 * * * *", "*/15 * * * *", "30 21 * * *"]`.

## Quarter-hour `*/15 * * * *` — autopay only, its own invocation

**Workers Paid gives one invocation 10,000 subrequests, so the ceiling is the 15-minute cron wall
clock, not the subrequest cap.** PhonePe calls are sequential at ~1 s each, so the scan is budgeted
at 600 calls and throughput comes from run size AND cadence.

**Autopay is NOT part of the hourly handler**, and putting it back re-creates the failure that split
it out: a separate cron expression gets a separate invocation, so at minute 0 the catalog rebuild
(R2 + KV + Neon) and the autopay scan each get a full budget. Sharing one blew the cap mid-scan, the
run died partway down its oldest-first list, the fresh rows behind the failing head were never
reached, and conversions sat at zero for over a day with dozens of debits due.

There is still exactly one scan per tick. A COMPLETED settle also charges 3 subrequests to the budget
for its reporter (a fetch plus a KV get and put).

Pass B skips any row notified less than 24 h ago **without making a call**: PhonePe refuses to execute
inside its own notify window (`SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED`), and a recycled order
re-notified by Pass A used to be executed by Pass B in the same run, every run. An order older than
PhonePe's 48 h retry window (aged from `notified_at`) is reconciled on the **top-of-hour tick only**:
it can settle only through PhonePe's own retries, so polling it every tick starved fresh executes.

**That deferral is a bound in Pass B's `WHERE`, not just a skip in its loop.** The loop runs below
`LIMIT MAX_ROWS_PER_PASS`, so a row it had already ruled out still spent one of the 200 slots — 56 of
150 fetched, measured in production. Slots are the scarce resource, not calls (a tick spends ~100 of
its 600), and the row cap is exactly what starves fresh debits behind an old head. `isTopOfHourTick()`
is read ONCE per run and shared by the bound and the skip: a scan long enough to outlive a 15-minute
boundary must not fetch a row under one rule and drop it under the other.

## Hourly `0 * * * *`

1. **build-catalog** — a no-op if `content_version` is unchanged, so most hours only rewrite
   `app_config.json` and `version.json` (whose `built_at` moves on every successful run; the
   `content_version` inside it is the change signal).
2. → **sweep-canonical**, but *only* after a rebuild that both fully succeeded and actually touched a
   scope. On-change convenience, not the safety net.

## Daily `30 21 * * *` (21:30 UTC = 03:00 IST, off-peak)

The unconditional backstop for whatever the on-change hourly sweep missed.

3. **sweep-canonical** — unconditional this time. Deletes `wallpapers/…`, `ringtones/…` AND
   `thumbs/…` objects that no DB row references; `full_key`, `audio_key` and `cover_key` all count,
   and **`thumbs/` references are DERIVED from `full_key`** (`thumbKeyFor`), not stored in any
   column. This is why the bucket can never be shared with another app.
4. **sweep-submissions** — reclaim orphaned `user/…/submissions/` R2 objects and expire 30-day-old
   pending rows. "Expire" is a status flip to `rejected` with a reason, **not** a delete.
5. **Popularity refresh** — bumps `app_config.content_version` when `SUM(apply_count) +
   SUM(set_count)` has moved since the last bump (tracked in KV `popularity_total`). It does NOT
   rebuild: the next hourly run sees the new version and republishes through the normal path. This is
   the ONLY thing that publishes accumulated applies, because the browse feed never reads the DB.
   Daily and not hourly: popularity is a sort key, and refreshing it hourly would re-download the
   whole catalog on every client 24× a day. A quiet day is a no-op rather than a forced re-download.

## Rehearse a cron change before it ships

`node tools/cron-rehearse.mjs hourly|daily|autopay` fires ONE trigger through a local `wrangler dev
--test-scheduled` against the Neon `debug` branch with local KV/R2 and PostHog blackholed, so nothing
it does can reach production. It refuses `--remote`, refuses to run unless the local Hyperdrive string
is the debug branch, and refuses autopay unless `.dev.vars` says `PHONEPE_ENV=SANDBOX` and
`--allow-autopay` is passed — autopay talks to PhonePe. The scheduled handler answers `/__scheduled`
at once and works in `ctx.waitUntil` -> read the `[cron] … complete` lines it streams afterwards,
not the HTTP status. The canonical sweep has a preview for the same reason: `POST
/internal/sweep-canonical?dry_run=1` returns `wouldDelete` and deletes nothing.

## Sweep failsafes — do not weaken either

- **Zero referenced keys ABORTS that prefix** rather than reading "no references" as "delete
  everything". A sweep once wiped live media in Pakiza; this is the fix.
- **A blast-radius cap** refuses a delete covering too large a fraction of the prefix, with a floor
  below which the fraction is not applied. The empty-set guard alone is what let the original wipe
  through — keep both.

## Cold-connection hazard — the crons' one real failure mode

**Arul's Neon endpoint never scales to zero** (`suspend_timeout_seconds = -1`, owner's call): the
compute was already awake ~95% of the month, so always-on costs under a dollar over the 0.25 CU floor
and removes the 1–2 s wake from the last few percent of first logins. **The autoscaling ceiling is
1 CU** (owner's call): the compute averages ~0.33 CU while awake and browse never touches the DB, so
the ceiling is the only setting that can blow the budget — at 8 CU a runaway cron bills ~$620/month,
at 1 CU ~$77 worst case. Raise it only on evidence from `pg_stat_statements` (installed) that queries
queue at 1 CU. Pakiza's endpoint still suspends and still carries the 8 CU ceiling — its traffic is
too thin to pay for always-on. The defences below stay load-bearing: Neon's weekly maintenance window restarts the
compute and severs the pooled socket exactly like a suspend did.

Before that, this Worker idled for hours (browse never touches the DB), so Neon suspended and
Hyperdrive's pooled connection went stale. The first query of a cron run then lands on a severed socket, and postgres.js
defaults `connect_timeout` to **30 s** — longer than a scheduled invocation can afford — so the run
hangs for its full budget and is killed by the runtime, taking the rebuild AND the renewal scan with
it. Observed in Pakiza: killed the hourly cron for hours before anyone noticed, because a dead cron
logs nothing.

Three defences, all load-bearing — do not remove one assuming the others cover it:

- `connect_timeout: 5` in `lib/db.ts` — fail fast instead of hanging.
- **Retry the first query once on a fresh connection** — `build-catalog` on its `app_config` read,
  `autopay-notify` on a `SELECT 1` before its passes. postgres.js reconnects transparently, so the
  second attempt succeeds.
- `await sql.end().catch(() => {})` — tearing down an already-severed socket can itself reject, and
  inside a `finally` that rejection **replaces the return value**, turning a fully successful rebuild
  into a failed promise.

## Proving a cron is alive

`catalog/app_config.json` is rewritten on every successful run, so its `Last-Modified` is the
liveness signal. `version.json` is rewritten too — `built_at` moves regardless; only its
`content_version` signals an actual content change.

```bash
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/app_config.json?cb=$RANDOM" | grep -i last-modified
npx wrangler tail --format json          # live, over a :00 boundary
```

Cache-bust here specifically (`?cb=`) — a `REVALIDATED` edge response can serve a stale
`Last-Modified`. That is the one place a cache-buster is right; while measuring cache behaviour it is
wrong ([caching.md](caching.md)).
