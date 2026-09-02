# Known Issues

Two things belong here: what is **broken or unverified right now**, and **traps that already cost
real time**. Nothing else. No changelog — git log holds it; close a line by deleting it.

## Open

- **Meta deferred deep links are unproven until the App Ads Helper "Test deep link" run** (recipe in
  [deferred-links.md](deferred-links.md) §Meta). The installed `fb<id>://open` path and both debug
  seams ARE proven on the A001. Also needed: the Meta App Dashboard → Settings → Android entry
  (package + `…arul.MainActivity`) for the scheme form.
- **Google Ads native DDL has never run on a device, and the referral reward has never been proven
  end-to-end.** The GA4F bridge is compile- and test-verified only; proving it needs a diagnostic DDL
  against the test phone's AdID, `debug.deferred.deeplink` set, a fresh Play install, and
  `wallpaper_engaged` carrying the requested UUID exactly once —
  [deferred-links.md](deferred-links.md) §Google Ads DDL. Separately: the full
  uninstall→Play-install→launch test used a wallpaper-ONLY URL, so `w=<uuid>` is signed off but
  `?ref=<code>` → new user → inviter reward is not. A visual landing does not prove referral credit;
  check the backend relationship.
- **Everything the CMS uploads carries no origin `Cache-Control`** — its presign signs `Content-Type`
  alone, as this repo's own user-upload presign does, while tool-imported objects are stamped
  `max-age=31536000, immutable`. **You cannot see the difference from the CDN**: the media Cache Rule
  rewrites the browser TTL, so both answer identically. Latent only while that rule stands
  ([caching.md](caching.md)); if it goes, fix with an S3 CopyObject metadata rewrite
  (`MetadataDirective=REPLACE`) AND add the header to the presign, or it recurs.
- **`ANDROID_CERT_SHA256` in `wrangler.toml` is DEAD CONFIG.** It and `POSTHOG_HOST` are bare
  top-level keys with no `[vars]` table anywhere in the file, so wrangler discards both with only a
  warning (`Unexpected fields found in top-level field`). The value that actually serves is the
  same-named **secret**, and it differs: the live `assetlinks.json` carries two fingerprints while
  the toml line lists three. Nothing is broken today — the device verifies against the first — but
  the file no longer describes the deployment. Decide whether to restore `[vars]` and drop the
  secret, or delete the dead keys and keep the secret, and whether the third fingerprint belongs.
  Same class of bug as the `[triggers]` trap below, mirrored.
- **Four shipped surfaces are hardcoded English and never read `AppLocalizations`** — a Tamil user
  sees English on them. `sign_in_screen.dart` and `apply_sheet.dart` contain ZERO `l10n.` references
  (the app's first screen, and the apply sheet's title plus its three targets), and `FeedEmpty`
  hardcodes its title, body and "Browse all". Translations are already sitting unused in the six
  ARBs; "Browse all" has no key at all. The l10n matrix pins this: those registry entries carry
  `unlocalizedEnglish: true`, which ASSERTS the screen attributes keys in `en` and none in the other
  five — localize one and the assertion fails, which is the signal to delete the flag in the same
  change. The fourth is LATENT and carries no flag: the wallpaper feed's All chip is the literal
  `_kAllLabel = 'All'` while the ringtones tab's reads `l10n.categoryAll`. They agree today only
  because `categoryAll` is demoted; restore its translations and the chip localizes on one tab only.
- **Four English-baseline layout defects the l10n matrix records and cannot fix by demotion** (a slot
  too small for English is too small for every language). `english_baseline.g.dart` is the generated
  subtraction set that keeps the suite green on them; run `flutter test test/l10n/` to see them. The
  sign-in Google pill ellipsizes "Continue with Google" at 320dp even at scale 1.0 · the language
  sheet overflows the bottom at every gating configuration · the upload screen overflows right at
  320dp/1.3 · the Refer CTA truncates "Share via WhatsApp" there. The profile row's email ellipsis
  is designed. The envelope also carries a non-gating `411x891@1.3-sweep` frame — a modern phone at
  accessibility text size, added after an on-device sweep found the language sheet overflowing.
- **No PhonePe webhook has ever been delivered, and it measurably costs row accuracy.** Cause and
  evidence: [phonepe.md](phonepe.md) §The webhook. A full read of all 185 live mandates found
  **6 rows (3.2%) drifted** — 4 `REVOKED` and 2 `PAUSED` at PhonePe while Neon still says `trialing`,
  which are exactly the two states only the webhook reports. The revoked ones keep climbing the
  dunning ladder against a dead mandate. `POST /payments/status` per subscriber parks them; the
  durable fix is the webhook.
- **The portrait lock does not hold on Android 16 — the same leak Pakiza already closed.**
  `screenOrientation="portrait"` is SILENTLY IGNORED at targetSdk 36: platform_compat
  `UNIVERSAL_RESIZABLE_BY_DEFAULT` (357141415, `enableSinceTargetSdk=36`) makes every activity
  resizable and free to rotate. Google documents it as large-screens-only (sw≥600dp); **it is not** —
  reproduced against Pakiza on a Nothing A001 at **sw411dp**, where MainActivity's window went
  landscape. Arul's manifest is in the identical state (neither `android:resizeableActivity` nor the
  compat property appears anywhere in `android/`), so it rotates too — nobody has looked. **Fix,
  verified on device in Pakiza:** `android:resizeableActivity="false"` on MainActivity AND the
  `<application>` property `android.window.PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` = `"true"`.
  The property is what holds; the attributes alone do not, and Google calls the opt-out temporary.

## Traps already paid for

- **A wallpaper engine surface gets NO aspect handling for free** — fixed in both repos
  ([wallpaper-apply.md](wallpaper-apply.md)). Media3 documents `setVideoScalingMode` as
  `SurfaceView`-only; on an engine surface it works ANYWAY, and `dumpsys SurfaceFlinger` still shows
  the pre-fix scale factors — only a screenshot correlated against both renders proves it.
- **Per-SIM ringtone keys must be ENUMERATED, not guessed** — fixed in both repos
  ([ringtones.md](ringtones.md)). In the fallback probe Android 12+ throws on a key the framework
  declares `@hide` and returns null for one it does not — **the throw is the POSITIVE signal**.
- **The static apply path does NOT distort — verified on device; stop re-deriving it.** The OEM
  zoom-crops UNIFORMLY, past the minimum cover.
- **`FlutterError.onError` must WRAP Crashlytics, never replace it** — fixed in both repos; do not
  regress it. Assigning `recordFlutterFatalError` directly drops `FlutterError.presentError`, so
  nothing is printed: a `RenderFlex overflowed` still paints its banner but produces ZERO logcat
  output, and the widget-tree dump naming the widget is gone. A device sweep that harvested logcat
  therefore reported zero overflows across every locale while the screenshots plainly showed the
  banner — a false clean bill of health. `main.dart` calls `presentError(details)` before forwarding,
  and `tools/l10n/scan_overflow_banner.py` reads the pixels regardless.
- **Media3 ≥ 1.8.0 cannot run Transformer below API 31, and it kills the PROCESS, not the call.**
  `ExoPlayerAssetLoader.Factory` holds unguarded `android.media.metrics.LogSessionId` (API 31)
  references, so `Transformer.start()` throws `NoClassDefFoundError` on Android 9–11. Verified in
  shipped bytecode: 1.7.1 clean, 1.8.0+ unguarded;
  [androidx/media#2535](https://github.com/androidx/media/issues/2535) was OPEN when last read — a
  version bump does NOT fix it and no ProGuard rule can (platform class). It was fatal because the
  channel caught `Exception` and `NoClassDefFoundError` is an `Error` — `ShareWatermarkChannel`
  catches **`Throwable`** now; keep it that way, in both apps. Consequence: live shares below API 31
  go out unwatermarked (`share_watermark_skipped`). Fixing it means pinning back to 1.7.1 (many
  releases of decoder workarounds; the tree is far past it) or hand-rolling MediaCodec+GL. Never
  re-open the catch.
- **A bare key written UNDER a `[table]` header in `wrangler.toml`.** `workers_dev = true` below
  `[triggers]` becomes `triggers.workers_dev`; with `[[routes]]` declared, workers.dev defaults OFF —
  the custom domain stays healthy while that host serves error 1042, killing every installed build
  with nothing visible in hand-testing. Wrangler warns and deploys anyway. **Bare top-level keys go
  ABOVE the first `[table]` header — but a key belonging in `[vars]` still needs that header** (the
  item above is the same trap inverted). `npx wrangler deploy --dry-run` prints the warning.
- **Measure the CDN with GET, never `curl -I`** — HEAD does not populate the cache, so a correct rule
  answers DYNAMIC on a URL a GET reports HIT a second later ([caching.md](caching.md)).

- **No per-path exclusion on the catalog Cache Rule** — it de-caches the pointer every cold start
  fetches ([caching.md](caching.md)).
- **Never set `PHONEPE_ENV` through a shell pipe** — a trailing newline once routed production
  credentials to the sandbox host as a 401 that looked like bad credentials. `isProduction()` now
  trims and THROWS, closing that path; the rule stands because every OTHER secret is compared
  untrimmed.
- **Two `wrangler dev` instances on port 8787** — the second bind does not fail loudly and the stale
  process serves old config as a phantom `502` or missing cron output. `netstat -ano | grep :8787` first.
- **A stub-issued OAuth token replayed against the real host** — the KV `phonepe:oauth` cache
  survives env, credential and host switches; delete it after any.
- **Never pass a `--dart-define` containing `&` on the command line.** On Windows `flutter` is a
  `.bat` and cmd.exe treats an unquoted `&` as a command separator, so the define arrives cut at the
  ampersand and the rest fails silently. Use `--dart-define-from-file`. The phone's shell does the
  same to `adb shell am start -d <url>` — quote the URL.
