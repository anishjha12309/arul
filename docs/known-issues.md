# Known issues

What is broken or unverified right now, and traps no other doc owns. Close a line by deleting it.

## Open

- **Android ≤11 reopens a dead Google sheet** after a crash or force-stop while it is in front:
  `singleInstancePerTask` is API 31+, so those phones keep singleTop and the icon returns the orphaned
  surface. Two Backs clear it. No manifest-only fix exists there — nothing of Arul's runs on that icon
  tap. Expected by mechanism ([auth.md](auth.md)), never walked on a ≤11 phone.
- **`activityClosed` sign-in failures are unexplained, and a legacy `GoogleSignIn` fallback cannot be
  built:** Google removed the Google Sign-In APIs from `play-services-auth` 22.0.0;
  `google_sign_in_android` pins 21.6.0, the last version that ships them, and drops them on its next
  bump. Credential Manager's GMS minimum is a 2023 build, so "old Play services" is unlikely.
- **Android 12's `surface_stripped` rate runs far above 11's and 13's, unexplained.** Its
  `User canceled the selector` is Play services' own selector ([auth.md](auth.md)); no back-out or icon
  strip on a 12L emulator produced it. It follows a dismissed One Tap sheet.
- **The Keystore fallback has never run on a phone that refuses with error -41** — only against a
  corrupted key blob on an Android 9 emulator ([launch-surface.md](launch-surface.md)). Read the
  non-fatal `keystore refused` against `login_success` on Android 8.1/9.
- **Funtouch (vivo, Android 9) can kill Arul ~30 s after a screen lock with Google's sheet up**
  (`am_kill … stop by com.vivo.abe`, no LMK), state-dependent, not deterministic. The next return is a
  cold start with a second automatic attempt and no outcome for the first — the shape of the ≤11
  "attempted, then nothing" bucket. OEM behaviour; nothing app-side to fix.
- **The feed's decoder grace can starve the paywall clip on a 2-decoder SoC — ACCEPTED (owner).**
  Leaving Wallpapers holds the decoders for `_leaveGrace` and `premium_screen.dart` builds its OWN pool,
  so Ringtones → a gated Set inside that window contends. It degrades to the mounted shutter, never a
  crash. The fix if it ever surfaces: `releaseDecoders()` before the premium screen builds its pool.
- **The referral reward has never been proven end to end.** `w=<uuid>` through a fresh Play install is
  signed off; `?ref=<code>` → new user → inviter reward is not. A visual landing proves nothing about
  credit — read the `referrals` row.
- **`ANDROID_CERT_SHA256` and `POSTHOG_HOST` in `wrangler.toml` are dead config** — bare top-level keys
  with no `[vars]` table, discarded with a warning ([workers/README.md](../workers/README.md) §Dev /
  deploy). The same-named SECRETS serve, and the cert secret differs: live `assetlinks.json` carries two
  fingerprints, the toml lists three. Open decision: restore `[vars]` and drop the secret, or delete the
  dead keys — and whether the third fingerprint belongs.
- **go_router's `popRoute` throws `Null check operator` on a system Back while a shell navigator is
  unmounted** (`_findCurrentNavigators`, flutter/flutter#188993). `SafeBackButtonDispatcher` contains it
  (non-fatal `router back`), which is why `ArulApp` hands MaterialApp the router's PARTS, not
  `routerConfig`. Drop both once flutter/packages#12111 ships.
- **Flutter's engine ANRs with main waiting in `FlutterJNI.nativeSurfaceCreated` /
  `onSurfaceDestroyed`** — a surface created on the return from Google's sheet, or destroyed on a
  backgrounding, across OEMs on Android 11–14 including phones already on OpenGL, so Impeller is not the
  lever (owner: no app change). Upstream flutter/flutter#169585; #174748 traced one to the merged
  platform/UI thread. Re-read on every Flutter upgrade.
- **No PhonePe webhook has ever been processed** ([phonepe-webhook.md](phonepe-webhook.md)), so a
  mandate revoked or paused in the UPI app stays `trialing` in Neon until a debit fails, and a revoked
  one climbs the dunning ladder against a dead mandate. `POST /payments/status` per subscriber parks it.
- **Account deletion rewrites subscription history.** `DELETE /me` cascade-deletes the `subscriptions`
  row, so that trial vanishes from every past cohort on the CMS subscriptions page; re-signup then
  inserts a synthetic `expired` row carrying the OLD `trial_end`, which lands back in the original
  cohort as "expired, never converted" even if they had paid. The tombstone stores only `trial_end`,
  and widening it would put PII behind the trial-farming guard. Read cohort counts as "≥".

## Traps already paid for

- **The manifest's `screenOrientation="portrait"` ALONE is ignored at targetSdk 36** — platform_compat
  `UNIVERSAL_RESIZABLE_BY_DEFAULT` frees every activity to rotate, phones included. The RUNTIME
  `SystemChrome.setPreferredOrientations` in `main()` is what holds Arul upright; never trade it for a
  manifest attribute. On sw600dp+ Android 16 ignores that too, so the `<application>` property
  `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` keeps the portrait UI in compat mode. Android calls
  that opt-out temporary: before a targetSdk that drops it, the fix is a layout that adapts.
- **`FlutterError.onError` must WRAP Crashlytics, never replace it.** Assigning
  `recordFlutterFatalError` directly drops `FlutterError.presentError`: a `RenderFlex overflowed` still
  paints its banner but logs NOTHING, so a logcat sweep reported zero overflows in every locale while
  the screenshots showed them. `main.dart` calls `presentError(details)` before forwarding;
  `tools/l10n/scan_overflow_banner.py` reads the pixels regardless.
- **Media3 ≥ 1.8.0 cannot run Transformer below API 31, and it kills the PROCESS.**
  `ExoPlayerAssetLoader.Factory` holds unguarded `LogSessionId` (API 31) references, so
  `Transformer.start()` throws `NoClassDefFoundError` on Android 9–11 (androidx/media#2535). No version
  bump or ProGuard rule fixes it. `NoClassDefFoundError` is an `Error`, so `ShareWatermarkChannel`
  catches **`Throwable`** — never narrow it. Consequence: live shares below API 31 go out unwatermarked
  ([share.md](share.md)). Fixing it means pinning back to 1.7.1 or hand-rolling MediaCodec+GL.
- **Never pass a `--dart-define` containing `&` on the command line.** On Windows `flutter` is a `.bat`
  and cmd.exe treats an unquoted `&` as a command separator, so the define arrives cut and the rest
  fails silently. Use `--dart-define-from-file`.
- **`tools/drive.mjs dump` returns stale accessibility XML across activity transitions on Android 9**
  (it kept echoing Google's sheet after the wall was back) — cross-check with `screencap`.
