# Crons — the four triggers and the cold-connection hazard

Read before adding, splitting or "simplifying" a scheduled handler. `workers/wrangler.toml [triggers]` is
the truth for the expressions; deploying ships that list, so a removed line silently removes that cron.

## Separate expressions are separate budgets — keep them apart

A separate cron expression gets a separate invocation, so each trigger owns a full wall clock and
subrequest budget. **Autopay was once part of the hourly handler**: at minute 0 the catalog rebuild
(R2 + KV + Neon) and the autopay scan shared one invocation, the scan blew the cap mid-list, the fresh
rows behind a failing head were never reached, and conversions sat at zero for over a day. Never fold
two jobs back into one trigger.

**A cron on an interval under an hour (quarter-hour, every-minute) gets only 30 s of CPU per
invocation**; the hourly and daily crons get 15 min (Workers limits, "CPU time per Cron Trigger").
Awaiting PhonePe or Neon is not CPU, but any per-row hashing or JSON work added to those two is charged
against the 30 s.

## `0 * * * *` — catalog

1. **build-catalog** — a no-op when `content_version` is unchanged, so most hours only rewrite
   `app_config.json` and `version.json` (`built_at` moves on every successful run; the
   `content_version` inside it is the change signal).
2. → **sweep-canonical**, only after a rebuild that fully succeeded AND touched a scope. On-change
   convenience, not the safety net.

## `*/15 * * * *` — autopay only

Workers Paid gives one invocation 10,000 subrequests, so the ceiling is the 15-minute wall clock:
PhonePe calls run sequentially at ~1 s, so a run is budgeted at 600 calls and throughput comes from run
size AND cadence. Exactly one scan per tick. Pass logic, the 24 h skip, the top-of-hour deferral and
Pass D: [autopay-debits.md](autopay-debits.md).

## `* * * * *` — campaign push only

Its own invocation for the same reason: a large drain must never share a wall clock with the catalog
rebuild. Claims NOTHING unless `PUSH_ENABLED` is exactly `"true"`, and logs nothing on an idle minute —
at 1,440 ticks a day a line per tick buries everything else. The registry prune an idle tick runs logs
only when it deleted something. Rules: [push.md](push.md).

## `30 21 * * *` — daily backstop (21:30 UTC = 03:00 IST, off-peak)

3. **sweep-canonical**, unconditional. Deletes `wallpapers/`, `ringtones/` AND `thumbs/` objects no DB
   row references; `full_key`, `audio_key` and `cover_key` all count, and **`thumbs/` references are
   DERIVED from `full_key`** (`thumbKeyFor`), stored in no column. This is why the bucket can never be
   shared with another app. Objects younger than 12 h are never swept (`CANONICAL_GRACE_MS`) — a CMS
   create in progress has no row yet.
4. **sweep-submissions** — reclaims orphaned `user/<sub>/submissions/` objects and expires 30-day-old
   pending rows as a status flip to `rejected` with a reason, never a delete.
5. **Popularity refresh** — bumps `app_config.content_version` when `SUM(apply_count) + SUM(set_count)`
   moved since the last bump (KV `popularity_total`); the next hourly run republishes. The ONLY thing
   that publishes accumulated applies, because the feed never reads the DB. Daily, not hourly: every
   bump re-downloads the whole catalog on every client.
6. Push cleanup — see [push.md](push.md).

## Sweep failsafes — never weaken either

- **Zero referenced keys ABORTS that prefix** rather than reading "no references" as "delete
  everything". A sweep once wiped live media; this is the fix.
- **A blast-radius cap** refuses a delete covering too large a fraction of the prefix, with a floor
  below which the fraction is not applied. The empty-set guard alone let the original wipe through.

## Rehearse a cron change before it ships

`node tools/cron-rehearse.mjs hourly|daily|autopay|push` fires ONE trigger through a local
`wrangler dev --test-scheduled` against the Neon `debug` branch with local KV/R2 and PostHog blackholed. It
refuses `--remote`, refuses unless the local Hyperdrive string is the debug branch, and refuses autopay
unless `.dev.vars` says `PHONEPE_ENV=SANDBOX` and `--allow-autopay` is passed. Push REALLY sends to the
debug branch's registered phones — it needs `--allow-push` and `PUSH_ENABLED=true` there. `/__scheduled`
answers at once and the work runs in `ctx.waitUntil` — read the `[cron] … complete` lines it streams, not
the HTTP status. The canonical sweep has a preview: `POST /internal/sweep-canonical?dry_run=1` returns
`wouldDelete` and deletes nothing.

## Cold connections — the crons' one real failure mode

**Arul's Neon endpoint never scales to zero** (`suspend_timeout_seconds = -1`, owner's call): it was
awake nearly all month anyway, so always-on costs little and removes the 1–2 s wake from first logins.
**The autoscaling ceiling is 1 CU** (owner's call): browse never touches the DB, so the ceiling is the
only setting that can blow the budget — a runaway cron at 8 CU bills eight times the 1 CU worst case.
Raise it only on `pg_stat_statements` evidence (installed) that queries queue at 1 CU.

The first query of a tick can still land on a severed socket: Neon's weekly maintenance restarts the
compute, and **Hyperdrive closes an origin connection idle for 10 minutes**, shorter than the gap
between quarter-hour ticks. postgres.js defaults `connect_timeout` to 30 s, so a run once hung its whole
budget and was killed — taking the rebuild AND the renewal scan with it, silently, because a dead cron
logs nothing. Three defences, all load-bearing:

- `connect_timeout: 5` in `lib/db.ts` — fail fast instead of hanging.
- **Retry the first query once on a fresh connection** — `build-catalog` on its `app_config` read,
  `autopay-notify` on a `SELECT 1` before its passes.
- `await sql.end().catch(() => {})` — tearing down a severed socket can reject, and inside a `finally`
  that rejection **replaces the return value**, turning a successful rebuild into a failed promise.

## Proving a cron is alive

`catalog/app_config.json` is rewritten on every successful hourly run, so its `Last-Modified` is the
liveness signal:

```bash
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/app_config.json?cb=$RANDOM" | grep -i last-modified
npx wrangler tail --format json          # live, over a :00 boundary
```

Cache-bust HERE (`?cb=`) — a `REVALIDATED` edge response can serve a stale `Last-Modified`. While
measuring cache behaviour a buster is wrong ([caching.md](caching.md)).
