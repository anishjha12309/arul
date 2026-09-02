---
description: Crons, cold-connection defences, sweep failsafes.
paths:
  - "workers/src/cron/**"
  - "workers/src/index.ts"
  - "workers/wrangler.toml"
---

- **Three cron triggers, and autopay has its own.** `0 * * * *` (catalog, then the on-change
  canonical sweep) · `*/15 * * * *` (autopay only) · `30 21 * * *` (unconditional sweeps plus the
  popularity version bump). A separate expression gets a separate invocation; sharing one blew the
  subrequest cap mid-scan and stopped conversions for over a day. Never fold autopay back in.
- **The cold-connection defences are three, all load-bearing** — `connect_timeout: 5`, a one-shot
  retry of the first query on a fresh connection, and `await sql.end().catch(() => {})` (a rejection
  inside a `finally` replaces the return value). Do not remove one assuming the others cover it.
- **Both sweep failsafes hold**: a zero referenced-key set ABORTS that prefix, and the blast-radius
  cap refuses an oversized delete. A sweep once wiped live media in Pakiza.
- **`thumbs/` references are DERIVED from `full_key`**, stored in no column — which is why the bucket
  can never be shared with another app.
- **A zero-row scope still writes a valid empty `all_1.json`.** A 404 there means the build FAILED.
- **In `wrangler.toml`, a key's position decides whether it deploys at all.** A bare key written
  UNDER a `[table]` header is captured by that table; a key that belongs in `[vars]` needs that
  header to exist. Wrangler only WARNS and deploys anyway, so read
  `npx wrangler deploy --dry-run`'s output. Both directions of this trap have already shipped
  ([docs/known-issues.md](../../docs/known-issues.md)).
- **Hyperdrive query caching stays OFF** (it caused ~60 s staleness).
- **`workers_dev = true` is load-bearing** — pre-rename installs still point at that host.
- Deploying ships cron changes: a removed line silently removes a cron.

Read [docs/cron.md](../../docs/cron.md); deploy with the `deploy-worker` skill — **deploy is part of
done**.
