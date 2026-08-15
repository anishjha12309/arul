# Known Issues

Two things belong in this file: what is **broken or unverified right now**, and **traps that already
cost real time** and would otherwise be paid for twice. Nothing else. No changelog — git log holds it;
close a line by deleting it.

## Open

- **Google Ads native DDL has never run on a device, and the referral reward has never been proven
  end-to-end.** The GA4F bridge is compile- and test-verified only; it is NOT in the installed Play
  Beta (1.0.0+33). Proving it needs a new AAB on a testing track, a diagnostic DDL registered against
  the test phone's AdID, `debug.deferred.deeplink` set, a fresh Play install, and `wallpaper_engaged`
  carrying the requested UUID exactly once — recipe in [deep-links.md](deep-links.md) §Google Ads DDL.
  Separately: the full uninstall→Play-install→launch test used a wallpaper-ONLY URL, so `w=<uuid>` is
  signed off but `?ref=<code>` → genuinely new user → inviter reward is not. A visual landing does not
  prove referral credit; check the backend relationship.
- **Everything the CMS uploads carries no origin `Cache-Control`** — its presign signs `Content-Type`
  alone, so this is not a pre-2026-07-29 backlog: a 2026-08-12 upload has no header either, while
  tool-imported objects carry `max-age=31536000, immutable`. Latent only because the media Cache Rule
  supplies the TTL at the edge — no rewrite is needed while that rule stands ([caching.md](caching.md)),
  but if it is ever removed or narrowed, fix with an S3 CopyObject metadata rewrite
  (`MetadataDirective=REPLACE`, server-side) AND add the header to the presign, or it recurs.

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
- **Never set `PHONEPE_ENV` through a shell pipe** — a trailing newline once routed production
  credentials to the sandbox host as a 401 that looked like bad credentials. `isProduction()` now
  trims and THROWS on anything but `PRODUCTION`/`SANDBOX` ([phonepe.md](phonepe.md)), so that exact
  path is closed; the rule stands because every OTHER secret is still compared untrimmed.
- **Two `wrangler dev` instances on port 8787** — the second bind does not fail loudly; the stale
  process keeps serving old config as phantom `502 phonepe_error` or missing cron output.
  `netstat -ano | grep :8787` before blaming code.
- **A stub-issued OAuth token replayed against the real host** — the KV `phonepe:oauth` cache
  survives env/credential/host switches; delete it after any ([phonepe.md](phonepe.md)).
