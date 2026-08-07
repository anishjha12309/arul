# Known Issues

Two things belong in this file: what is **broken or unverified right now**, and **traps that already
cost real time** and would otherwise be paid for twice. Nothing else. No changelog — git log holds it;
close a line by deleting it.

## Open

- **The CMS ringtone cover field has never been exercised** — all rows ship `cover_key = null` by
  design, so `ringtones/covers/…` is an empty prefix the sweep has never had to consider.
- **Media imported before 2026-07-29 carries no origin `Cache-Control`** — the media Cache Rule
  covers them at the edge, so latent, but it bites if that rule is removed or narrowed. Fix with an
  S3 CopyObject metadata rewrite (`MetadataDirective=REPLACE`; server-side, no egress).

## Traps already paid for

- **Media3 ≥ 1.8.0 cannot run Transformer below API 31, and it kills the PROCESS, not the call.**
  `ExoPlayerAssetLoader.Factory` holds unguarded `android.media.metrics.LogSessionId` (API 31)
  references, so `Transformer.start()` throws `NoClassDefFoundError` on Android 9–11. Verified in
  shipped bytecode: 1.7.1 clean · 1.8.0+ unguarded; [androidx/media#2535](https://github.com/androidx/media/issues/2535)
  is OPEN — a version bump does NOT fix it and no ProGuard rule can (platform class). It was fatal
  because the channel caught `Exception` and `NoClassDefFoundError` is an `Error` — everything in
  `ShareWatermarkChannel` catches **`Throwable`** now; keep it that way, in both apps. Consequence:
  live shares below API 31 go out unwatermarked (`share_watermark_skipped`). If that ever needs
  fixing: pin media3 1.7.1 (costs three releases of decoder workarounds) or hand-roll
  MediaCodec+GL — never re-open the catch.
- **A bare key written UNDER a `[table]` header in `wrangler.toml`.** `workers_dev = true` below
  `[triggers]` becomes `triggers.workers_dev`; with `[[routes]]` declared, workers.dev defaults OFF —
  the custom domain stays healthy while `arul-api.<subdomain>.workers.dev` serves error 1042, killing
  every installed build with nothing visible in hand-testing. Wrangler warns
  (`Unexpected fields found in triggers`) and deploys anyway. Bare top-level keys go ABOVE the first
  `[table]` header; `npx wrangler deploy --dry-run` prints the warning — read it.
- **Measure the CDN with GET, never `curl -I`** — HEAD does not populate Cloudflare's cache, so a
  correct rule answers DYNAMIC ([caching.md](caching.md)).
- **No per-path exclusion on the catalog Cache Rule** — an exclusion de-caches the pointer every cold
  start fetches ([caching.md](caching.md)).
- **Never set `PHONEPE_ENV` through a shell pipe** — the trailing newline routes production
  credentials to the sandbox host as a 401 that looks like bad credentials ([phonepe.md](phonepe.md)).
- **Two `wrangler dev` instances on port 8787** — the second bind does not fail loudly; the stale
  process keeps serving old config as phantom `502 phonepe_error` or missing cron output.
  `netstat -ano | grep :8787` before blaming code.
- **A stub-issued OAuth token replayed against the real host** — the KV `phonepe:oauth` cache
  survives env/credential/host switches; delete it after any ([phonepe.md](phonepe.md)).
