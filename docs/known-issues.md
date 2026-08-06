# Known Issues

Two things belong in this file: what is **broken or unverified right now**, and **traps that already
cost real time** and would otherwise be paid for twice. Nothing else. A "fixed on `<date>`" changelog
does NOT belong here — git log already holds it, and a closed item left behind just rots. Close a
line by deleting it. Billing behaviour that is proven lives in [billing-verified.md](billing-verified.md).

## Open

- **Ringtone "Set" has never been run on a pre-Android-10 device.** API 29+ and below-29 are two
  different code paths in `MainActivity.setRingtoneFromFile`, and only the modern one has been
  exercised here. The pre-Q path — copy into the public Ringtones dir, register that path on the
  EXTERNAL volume, behind a runtime `WRITE_EXTERNAL_STORAGE` prompt — was ported from Pakiza on
  2026-08-05, where it was written against two real on-device failures (app-private path unreadable
  by the ringtone player; internal-volume row never validating as a ringtone). Ported, not
  re-verified: needs an API 23–28 handset. Arul had NO pre-Q path at all before that date, so every
  Set on such a device would have failed.

- **The Play listing must now justify `WRITE_SETTINGS` and (below API 29) `WRITE_EXTERNAL_STORAGE`.**
  Both are declared and both are genuinely reachable now that ringtones ship — the storage one is
  capped at `maxSdkVersion=28` so it does not appear for modern devices.

- **All 63 ringtones have `cover_key = null`** — by design (the app draws its kolam medallion), so
  the CMS ringtone editor's cover field has never been exercised against a real row and
  `ringtones/covers/…` is an empty prefix the sweep has never had to consider.

- **"Vetrivel Muruga" (30 s) and "Vetri Vel Muruga" (33 s) both ship** — different recordings (RMS
  envelopes do not match), so both were kept, but they read as a duplicate. Rename one in the CMS.
  From the same drop, "Venkat Ramana Govinda" is 49 s, the only track over the ≤40 s convention —
  harmless, a phone rings ~30 s.

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

- **Firebase ↔ Google Ads is not linked.** Only blocks install campaigns — `purchase`/`login` already
  reach GA4, so nothing is lost meanwhile. Three console steps, no code: [analytics-ops.md](analytics-ops.md).

- **No cron run observed on a genuinely cold connection.** The hourly cron succeeded at 11:00:01 on
  2026-07-29, but minutes after a deploy — a warm connection, which is the case that never fails.
  Watch `npx wrangler tail --format json` over a `:00` after several idle hours. Same residual as
  Pakiza.

## Traps already paid for

- **Media3 ≥ 1.8.0 cannot run Transformer below API 31, and it kills the PROCESS, not the call.**
  `ExoPlayerAssetLoader.Factory` holds a field, a constructor parameter and a `createAssetLoader`
  local of type `android.media.metrics.LogSessionId` (API 31) with **no `SDK_INT` guard**, so ART
  resolves it on every API level and `Transformer.start()` throws `NoClassDefFoundError` on Android
  9–11. Verified in shipped bytecode: **1.7.1 = 0 refs (clean) · 1.8.0 added the field · 1.9.2 and
  1.10.1 = 8 refs, unguarded.** [androidx/media#2535](https://github.com/androidx/media/issues/2535)
  is OPEN — bumping the version does NOT fix it, and no ProGuard rule can (it is a platform class).
  *Symptom:* Share on a LIVE wallpaper → black → launcher. *Why it was fatal instead of a degraded
  share:* the channel caught `Exception`, and `NoClassDefFoundError` is an `Error`. Everything in
  `ShareWatermarkChannel` catches **`Throwable`** now — keep it that way, in both apps.
  *Live consequence:* live shares below API 31 go out unwatermarked (`share_watermark_skipped`). If
  that ever needs fixing, the choices are pinning media3 to 1.7.1 (costs the feed three releases of
  decoder workarounds) or a hand-rolled MediaCodec+GL pipeline — never re-opening the gate.

- **A bare key written UNDER a `[table]` header in `wrangler.toml`.** *Symptom:* the custom domain is
  perfectly healthy while `arul-api.<subdomain>.workers.dev` serves a bare Cloudflare `error code:
  1042` page — so every already-installed build is dead and nothing you test by hand shows it.
  *Cause:* `workers_dev = true` sat below `[triggers]`, which captured it as `triggers.workers_dev`;
  with `[[routes]]` declared, workers.dev then defaults to OFF. Wrangler says so on every deploy
  (`Unexpected fields found in triggers field`) and deploys anyway. *Rule:* every bare top-level key
  goes ABOVE the first `[table]` header, and `[observability]` stays last. `npx wrangler deploy
  --dry-run` prints the warning — read it (found + fixed 2026-07-30).

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
