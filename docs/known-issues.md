# Known Issues

Two things belong in this file: what is **broken or unverified right now**, and **traps that already
cost real time** and would otherwise be paid for twice. Nothing else. A "fixed on `<date>`" changelog
does NOT belong here — git log already holds it, and a closed item left behind just rots. Close a
line by deleting it. Billing behaviour that is proven lives in [billing-verified.md](billing-verified.md).

## Open

- **Ringtones are PARKED for v1, not merely empty.** The `ringtones` table is empty in prod, so the
  tab only ever rendered "coming soon" — shipping a dead tab is worse than shipping no tab. The ENTRY
  POINT is therefore commented out: `lib/app/router.dart` serves `/browse` as a plain top-level route
  instead of the `StatefulShellRoute` (which takes the dock and the ringtones branch with it), and
  `AndroidManifest.xml` comments out `WRITE_SETTINGS` — special-access, Play-reviewed, and nothing
  behind it. Grep `RINGTONES-PARKED`.
  **Nothing is deleted and nothing here is a defect.** `features/ringtones/**`,
  `app/shell/app_shell.dart`, the `ringtone*` ARB keys, the worker's `ringtones` catalog scope and the
  `ringtones/` sweep prefix are intact and still type-checked; Dart tree-shakes them out of the build.
  **To un-park:** publish ringtone audio FIRST (R2 bytes + Neon rows + a rebuild — otherwise the tab
  is dead again), then uncomment the `StatefulShellRoute` block, delete the temporary `/browse` route,
  restore the `app_shell.dart` + `ringtones_screen.dart` imports, uncomment `WRITE_SETTINGS`, and drop
  the parked header on `app_shell.dart`. Full procedure and the dock reference screenshots:
  [reference/ringtones-parked/README.md](reference/ringtones-parked/README.md).

- **Media imported before 2026-07-29 carries no origin `Cache-Control`.**
  `tools/content-import/import.mjs` now stamps `public, max-age=31536000, immutable` on upload, but
  the ~614 objects already in the bucket carry only a `content-type`. The media Cache Rule ("ignore
  cache-control, use TTL") covers them at the edge, so this is latent rather than live — it bites only
  if that rule is removed or narrowed. Fix properly with an S3 CopyObject metadata rewrite
  (`MetadataDirective=REPLACE`; server-side, no egress) to make the objects self-describing.

- **Production webhook delivery for Arul is unverified** — PhonePe → `api.hsrutility.com` → `DKS_`
  dispatcher → arul-api. The one billing hop neither UAT nor local can cover; the same path already
  works in production for Pakiza. Needs a human watching a real production debit.

- **The daily 21:30 UTC sweep has never been observed running live** on this worker.

- **No cron run observed on a genuinely cold connection.** The hourly cron succeeded at 11:00:01 on
  2026-07-29, but minutes after a deploy — a warm connection, which is the case that never fails.
  Watch `npx wrangler tail --format json` over a `:00` after several idle hours. Same residual as
  Pakiza.

## Traps already paid for

- **Measuring the CDN with `curl -I`.** *Symptom:* `cf-cache-status: DYNAMIC` on an asset a Cache Rule
  plainly covers. *Cause:* HEAD does not populate Cloudflare's cache, so a host without warm traffic
  answers DYNAMIC — indistinguishable from a broken rule; an afternoon on 2026-07-29 went into fixing
  a rule that was correct from the start. *Rule:* measure cache with GET, never HEAD
  ([caching.md](caching.md)).

- **A `version.json` exclusion on the catalog Cache Rule.** *Symptom:* the pointer every cold start
  fetches serves `DYNAMIC`/~240 ms while its siblings serve `HIT`/~40 ms. *Cause:* the rule already
  says "use cache-control header if present", so the origin header alone decides — an exclusion only
  removes that. It kept Pakiza's pointer uncached for days. *Rule:* the catalog rule carries no
  per-path exclusions ([caching.md](caching.md)).

- **`PHONEPE_ENV` set through a shell pipe.** *Symptom:* `401 {"code":"401"}` from PhonePe that looks
  exactly like bad credentials. *Cause:* the trailing newline (`"PRODUCTION" | wrangler secret put`)
  makes the exact string compare fail, routing production credentials to the sandbox host. *Rule:* set
  secrets with `wrangler secret bulk <json>`, never a pipe ([phonepe.md](phonepe.md)).

- **Two `wrangler dev` instances on port 8787.** *Symptom:* a phantom `502 phonepe_error`, or cron
  output that simply never appears. *Cause:* the second bind does not fail loudly — the stale process
  keeps serving your requests with its old config. *Rule:* `netstat -ano | grep :8787` before blaming
  code.

- **A stub-issued OAuth token replayed against the real host.** *Symptom:* PhonePe rejects a request
  that worked minutes ago, right after switching between the local stub and real UAT (or flipping
  `PHONEPE_ENV`). *Cause:* the token is cached in KV under `phonepe:oauth` and neither switch
  invalidates it. *Rule:* delete `phonepe:oauth` after any env, credential or host change
  ([phonepe.md](phonepe.md)).
