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

- **Four shipped surfaces are hardcoded English and never read `AppLocalizations`** — a Tamil user
  sees English on them. `sign_in_screen.dart` and `apply_sheet.dart` contain ZERO `l10n.` references
  (the first screen of the app: "Continue with Google", "Choose an account to get started", "Terms",
  "Privacy"; the apply sheet: "Apply wallpaper" and its three targets), and `FeedEmpty`
  (`feed_states.dart`) hardcodes its title, body and "Browse all". Translations for all of them are
  already sitting unused in the six ARBs (`signInHeadline`/`signInBody`/`signInGoogle`/`signInTerms`,
  `applyTarget*`, `feedEmptyTitle`/`feedEmptyBody`); "Browse all" has no key at all. The l10n matrix
  pins this rather than hiding it: those registry entries carry `unlocalizedEnglish: true`, which
  ASSERTS the screen attributes keys in `en` and none in the other five — localize a screen and the
  assertion fails, which is the signal to delete the flag in the same change.
  The fourth is LATENT, so it carries no flag: the wallpaper feed's All chip is the literal
  `_kAllLabel = 'All'` in `feed_states.dart` while the ringtones tab's reads `l10n.categoryAll`.
  The two agree today only because `categoryAll` is demoted (English everywhere); restore its
  translations and the same chip localizes on one tab and not the other.
- **Four English-baseline layout defects the l10n matrix records and cannot fix by demotion** (a slot
  too small for English is too small for every language). All four are inside the gating envelope
  (320dp/360dp × text scale 1.0/1.3); re-run `flutter test test/l10n/` to see them, and
  `test/l10n/support/english_baseline.g.dart` is the generated subtraction set that keeps the suite
  green on them: the sign-in Google pill ellipsizes "Continue with Google" at 320dp even at scale 1.0
  (needs 149px in 140px) and by 52px at 1.3 · the language sheet overflows the screen bottom at every
  gating configuration (7.5–28px) AND at 411dp/1.3 by 8px — that last one is a modern phone at
  accessibility text size, not a narrow one, and it was invisible until an on-device sweep found it
  and `411x891@1.3-sweep` was added to the envelope · the upload screen overflows 29px to the right at 320dp/1.3 · the
  Refer CTA truncates "Share via WhatsApp" at 320dp/1.3. The profile row's email ellipsis is designed,
  not a defect.

- **The portrait lock does not hold on Android 16 — the same leak Pakiza just closed.**
  `screenOrientation="portrait"` is SILENTLY IGNORED at targetSdk 36: platform_compat
  `UNIVERSAL_RESIZABLE_BY_DEFAULT` (357141415, `enableSinceTargetSdk=36`) makes every activity
  resizable and free to rotate. Google documents it as large-screens-only (sw>=600dp); **it is not**
  — reproduced on a Nothing A001, **sw411dp**, Android 16 (2026-08-22, against Pakiza): auto-rotate
  off + `adb shell settings put system user_rotation 1` put MainActivity's own window at
  `Requested w=2392 h=1080`, config `land`. Arul's manifest is in the identical state, so it rotates
  too — nobody has looked. **Fix, verified on device in Pakiza:** `android:resizeableActivity="false"`
  on MainActivity AND the `<application>` property `android.window.PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY`
  = `"true"`. The property is what actually holds; the attributes alone do not, and the platform drops
  the opt-out at API 37. Reproduce with the adb line above, then port. (Recorded from Pakiza's
  overnight run; Arul's code untouched — it gets its own session.)

## Traps already paid for

- **A wallpaper engine surface gets NO aspect handling for free** — FIXED 2026-08-21, both repos
  ([edge-cases.md](edge-cases.md) §Wallpaper apply). Media3 documents `setVideoScalingMode` as
  `SurfaceView`-only; on an engine surface it works ANYWAY, and `dumpsys SurfaceFlinger` still shows
  the pre-fix `x=1.0547 y=1.3114` — only a screenshot correlated against both renders proves it.
- **Per-SIM ringtone keys must be ENUMERATED, not guessed** — FIXED 2026-08-21, both repos
  ([edge-cases.md](edge-cases.md) §Ringtones). In the fallback probe: Android 12+ throws on a key the
  framework declares `@hide` and returns null for one it does not — the throw is the POSITIVE signal.
- **The static apply path does NOT distort — verified 2026-08-21 on device; stop re-deriving it.** The
  OEM zoom-crops UNIFORMLY (sx 1.3707–1.3711 vs sy 1.3702–1.3707), past the 1.246 minimum cover.
- **`FlutterError.onError` must WRAP Crashlytics, never replace it** — FIXED 2026-08-21 in both
  repos; do not regress it. Assigning `FlutterError.onError = FirebaseCrashlytics.instance
  .recordFlutterFatalError` directly drops `FlutterError.presentError`, so nothing is printed: a
  `RenderFlex overflowed by N pixels` still paints its banner on screen but produces ZERO logcat
  output, and the widget-tree dump that normally names the offending widget is gone too. A device
  sweep that harvested logcat therefore reported zero overflows across every locale and
  configuration while the screenshots plainly showed the banner — a false clean bill of health.
  `main.dart` now calls `presentError(details)` before forwarding; Crashlytics still receives
  everything. `tools/l10n/scan_overflow_banner.py` reads the pixels regardless, which is what
  makes it trustworthy when a handler is misconfigured.

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
