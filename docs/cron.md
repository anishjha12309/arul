# Crons — the two triggers and the cold-connection hazard

Read this before adding, splitting or "simplifying" a scheduled handler. Declared in
`workers/wrangler.toml [triggers]` as `crons = ["0 * * * *", "*/15 * * * *", "30 21 * * *"]`.

## Quarter-hour `*/15 * * * *` — autopay only, its own invocation

**Workers Paid gives one invocation 10,000 subrequests, so the ceiling is the 15-minute cron wall
clock, not the subrequest cap** — PhonePe calls are sequential at ~1 s each, so the scan is
budgeted at 600 and throughput comes from run size AND cadence. Before this trigger existed the hourly run died partway down its oldest-first
list ("Too many subrequests"), the fresh rows behind the failing head were never reached, and
conversions sat at zero for 30+ hours with 58 debits due (2026-08-23 → 08-25). Autopay is NOT
part of the hourly handler: a separate cron expression gets a separate invocation, so at minute 0
the catalog rebuild (R2 + KV + Neon) and the scan each get a full budget — sharing one blew the cap
mid-scan at 04:00Z on 08-25. There is still exactly one scan per tick. A COMPLETED settle also
charges 9 to the budget for its three reporters (fetch + KV get/put each). Pass B also skips any row notified < 24 h ago without a call: PhonePe refuses to
execute inside its notify window (`SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED`), and a
recycled order re-notified by Pass A used to be executed by Pass B in the same run, every run.
An order older than PhonePe's 48 h retry window (age from `notified_at`) is reconciled on the
top-of-hour tick ONLY: it can settle only through PhonePe's own retries, and polling it every tick
cost 26 of the then-40-call budget per run on 08-25, starving fresh executes.

## Hourly `0 * * * *`

1. **build-catalog** — no-op if `content_version` is unchanged, so most hours only rewrite
   `app_config.json` + `version.json` (whose `built_at` moves every successful run — the
   `content_version` inside it is the change signal). → **sweep-canonical**, but *only* after a
   rebuild that both fully succeeded and actually touched a scope. On-change convenience, not the
   safety net.
2. **autopay notify + execute** is NOT here any more — it is the quarter-hour trigger above (the
   renewal path: Pass A notifies 24 h before each debit; Pass B redeems at `next_debit_at`; Pass C
   reconciles debits stuck `PENDING` for over 2 h; a KV `autopay:next_work_at` marker short-circuits
   idle ticks to one KV read). Putting it back in this handler re-creates the shared-budget failure.

## Daily `30 21 * * *` (21:30 UTC = 03:00 IST, off-peak)

The unconditional backstop for whatever the on-change hourly sweep missed.

3. **sweep-canonical** — unconditional this time. Deletes `wallpapers/…`, `ringtones/…` AND
   `thumbs/…` objects that no DB row references; `full_key`, `audio_key` and `cover_key` all count,
   and `thumbs/` references are DERIVED from `full_key` (`thumbKeyFor`), not stored in any column.
   This is why the bucket can never be shared with another app.
4. **sweep-submissions** — reclaim orphaned `user/…/submissions/` R2 objects and expire 30-day-old
   pending rows. "Expire" is a status flip to `rejected` with a reason, **not** a delete.
- **Popularity refresh** — bumps `app_config.content_version` when `SUM(apply_count) + SUM(set_count)` has moved since the last bump (tracked in KV `popularity_total`). It does NOT rebuild: the next hourly run sees the new version and republishes through the normal path. This is the ONLY thing that publishes accumulated applies — the browse feed never reads the DB, so a counter that moves changes nothing users see until a new `?v=` is minted. Daily, not hourly: popularity is a sort key, and refreshing it hourly would re-download the whole catalog on every client 24x a day. A quiet day is a no-op rather than a forced re-download.

## Sweep failsafe — do not weaken

When the DB reports **zero** referenced keys for a prefix, sweep-canonical ABORTS that prefix rather
than reading "no references" as "delete everything". A sweep once wiped live media in Pakiza; this
guard is the fix.

## Cold-connection hazard — the crons' one real failure mode

This Worker idles for hours (browse never touches the DB), so Neon suspends and Hyperdrive's pooled
connection goes stale. The first query of a cron run then lands on a severed socket. postgres.js
defaults `connect_timeout` to **30 s** — longer than a scheduled invocation can afford — so the run
hangs for its full budget and is killed by the runtime, taking the rebuild AND the renewal scan with
it. Observed in Pakiza: killed the hourly cron for 3 h before anyone noticed, because a dead cron
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
liveness signal. `version.json` is rewritten every successful run too — `built_at` moves regardless;
only its `content_version` signals an actual content change.

```bash
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/app_config.json?cb=$RANDOM" | grep -i last-modified
npx wrangler tail --format json          # live, over a :00 boundary
```

Cache-bust here specifically (`?cb=`) — a `REVALIDATED` edge response can serve a stale
`Last-Modified`. That is the one place the cache-buster is right; while measuring cache behaviour it
is wrong ([caching.md](caching.md)).
