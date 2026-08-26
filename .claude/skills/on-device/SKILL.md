---
name: on-device
description: Run and debug Arul on a real Android device — flutter run with dart-defines, adb logcat capture, the proven filters for PhonePe, video/surface, and analytics issues, and agent UI automation (tools/drive.mjs by-label taps, Dart MCP app driving).
---

# On-Device Run & Debug

**Run:** `adb devices` (must list one) → `flutter run --dart-define-from-file=env/dev.json`. Release feel: add `--release`. **`dev.json` already points at the LIVE production worker** — it differs from `prod.json` only in `GOOGLE_ANDROID_CLIENT_ID`, so a "dev" run writes real rows. `env/sbx.json` is the only local one (`API_BASE_URL=http://127.0.0.1:8787`, for the verify-payments harness).

**Logcat capture** (save to scratchpad, never the repo):
```bash
adb logcat -c && adb logcat > <scratchpad>/capture.txt   # reproduce, then Ctrl-C
```

Proven filters — grep the capture, don't eyeball:
| Problem | grep |
|---|---|
| PhonePe SDK failures | `PR004`, `B2bPgActivity`, `PG_PAY_V2`, `AutoPaySetup`, `[PremiumPurchase]` |
| Video/feed jank | `BLASTBufferQueue`, `ExoPlayer`, `FeedVideoPlugin`, `FeedVideo:`, `Choreographer.*Skipped` |
| Crashes/ANR | `FATAL`, `AndroidRuntime`, `ANR in` |
| Sign-in | `GoogleSignIn`, `ApiException`, `[ApiAuthService]` |

`Skipped` is capital-S in AOSP — a lowercase grep matches nothing. The app's own tags —
`FeedVideoPlugin`, `FeedVideo:`, `[ApiAuthService]`, `[PremiumPurchase]` (plain `debugPrint`),
`[boot]` (`kReleaseMode`-gated) — are all readable in **debug and profile**. Never grep
`VideoOutput` — that was media_kit's tag, and this app ships Media3 only.

**A release build is SILENT by design** (owner directive 2026-08-24): `main()` reassigns
`debugPrint` to a no-op under `kReleaseMode`, so every Dart log — this app's and every package's —
is gone, and `-assumenosideeffects android.util.Log` strips Kotlin `v/d/i` (`w/e` are KEPT:
operational error diagnostics). So `--release` is the wrong build to debug on: grep it and you get
nothing, which reads exactly like a broken feature. Use **profile** (`--profile`) — AOT-true and
fully logged — or, when the release binary itself is the suspect, sideload one built with
`--dart-define=DIAG=true` to bring the Dart logs back (Kotlin `v/d/i` stay stripped — `DIAG` gates
only `debugPrint`). **A Play install shows only Kotlin `Log.w/e` and native/system lines** (`CCodec`,
`ActivityTaskManager: Displayed`, `MediaCodec`) — no Dart line, no `FeedVideoPlugin`/`FA` chatter;
beyond those, Crashlytics is the only diagnostic channel that reaches it.

Known-benign: `BLASTBufferQueue ... max frames` while the feed idles = compositor noise, 0 crashes — do NOT chase it.

**Measuring speed on device** — frame timing, cold start, jank: read
[docs/perf-measurement.md](../../../docs/perf-measurement.md) FIRST. `dumpsys gfxinfo` reads 0
frames for a Flutter app, an idle feed scores ~70% "janky", and logcat's default buffer eats the
early `[boot]` marks — each of them cost real time once. Measure on a PROFILE build.

**Screenshots still work here.** `FLAG_SECURE` is applied only when the installer is
`com.android.vending`, so `flutter run` builds and sideloaded release APKs stay capturable
(`scrcpy`, `adb exec-out screencap`). A build installed *from Play* blanks screenshots, screen
recording and the recents thumbnail — driving that one visually is impossible; read logcat instead.

**Ringtone Set below Android 10** takes a different code path (public Ringtones dir + a runtime
`WRITE_EXTERNAL_STORAGE` prompt) than API 29+ — when touching Set, exercise BOTH paths: a modern
phone alone never executes the pre-Q branch.

**GA4 DebugView:** `adb shell setprop debug.firebase.analytics.app com.hsrutility.arul` → Firebase console → DebugView. Off: same command with `.none.` (trailing dot — that exact sentinel). Release builds have no DebugView, and the in-app `FA` tag is `Log.v/d` (R8-stripped, `DIAG` does not restore it) — in release only the Play-services side `FA-SVC` survives (docs/analytics-ops.md).

**Wallpaper-apply testing:** apply triggers an OS activity recreate — the `configChanges` fix must keep the app alive; a cold restart on apply = regression (docs/edge-cases.md).

**Video QC on budget devices:** watch for green edge strips on live cards (dimension rule violated or
software-decoder fallback — see docs/media-conventions.md) and for black cards (decoder budget).

**Automate the loop — act by label, not screenshot.** Two layers, split by scope:

*In-app (Dart MCP server, repo `.mcp.json` — approve it on first session):* run with the driver
extension on top of the usual defines —
`flutter run --dart-define-from-file=env/dev.json --dart-define=ENABLE_FLUTTER_DRIVER=true` —
then connect to the running app: the server's `dtd` tool discovers it and `flutter_driver_command`
taps/types/scrolls by label; hot reload, runtime errors and the widget tree come as tools too (no
logcat round-trip for Dart exceptions). Without the define the extension is compiled out — driving
fails, the read-side tools still work.

*System surfaces + everything adb can see (`tools/drive.mjs`):* the OS wallpaper chooser, the
modify-system-settings grant, the One Tap sheet — app-scoped drivers stop at these; adb does not.
`dump` prints the screen as `(x,y) [tap] "label"` lines, so the loop is dump → tap with no image
in context:
```bash
node tools/drive.mjs dump              # in-app labels need a DEBUG build (semantics — main.dart)
node tools/drive.mjs tap "Ringtones"   # substring match on text/content-desc; --index N on ties
node tools/drive.mjs swipe up          # fling the feed (down|left|right, --dist px, --ms n)
node tools/drive.mjs open "https://arul.hsrutility.com/w/<id>"   # deep link — skip the tapping
adb shell "am start -a android.intent.action.VIEW -d 'fb<META_APP_ID>://open?ringtone_id=<id>&lang=hi'"  # Meta form — INNER quotes or the phone's shell eats the &
node tools/drive.mjs current           # focused window: how you detect an OS surface on top
# also: tap x y · type · key back|wake|… · launch · stop · shot [path] · unlock
```
A missed `tap` prints what IS on screen, so one failure self-corrects.

**Deferred deep links on a sideloaded build:** `DEBUG_INSTALL_REFERRER` / `DEBUG_DEFERRED_LINK` stand in
for Play's referrer replay and the GA4F/Meta fetch (debug only, once per install — `adb shell pm clear`
between runs). Pass them through a `--dart-define-from-file` JSON, never on the command line: cmd.exe
cuts a bare `--dart-define` at its first `&`. Recipes: docs/deferred-links.md. Release/profile builds are
label-less BY DESIGN (empty FlutterView) — drive them by coordinates or not at all.

**Automation guard-rails.** dev.json points at the LIVE worker: a signed-in automated run writes
real rows, and every gated `action=apply` bumps public popularity ranking — keep loops off
Apply/Set on real accounts, and never drive a real PhonePe sheet (verify-payments is the harness
for that). Screenshots answer visual questions ONLY — a live card that hasn't decoded yet is
pixel-identical to a static one BY DESIGN; prove video from logcat (`FeedVideoPlugin`,
`FeedVideo: first frame revealed` — debug/profile; on a release build the native
`CCodec: Created component [c2.mtk.avc.decoder]` line is the only decode anchor), never from pixels.
