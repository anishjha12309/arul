---
name: on-device
description: Run and debug Arul on a real Android device — flutter run with dart-defines, adb logcat capture, the proven filters for PhonePe, video/surface, and analytics issues, and agent UI automation (tools/drive.mjs by-label taps, Dart MCP app driving).
disable-model-invocation: true
---

# On-Device Run & Debug

**Run:** `adb devices` (must list one) → `flutter run --device-user 0 --dart-define-from-file=env/dev.json`; release feel: add `--release`. **`dev.json` points at the LIVE worker** (only `GOOGLE_ANDROID_CLIENT_ID` differs from `prod.json`), so a run writes real rows; `env/sbx.json` (`127.0.0.1:8787`) is the only local one. **On the owner's phone install for user 0 only** (`--device-user 0`, `adb install --user 0`) **and `adb shell pm uninstall com.hsrutility.arul` before handing it back**: a plain install also lands in Private space, and its kept data leaves a differently signed record that blocks the Play install.

**More than one target attached — a phone and an emulator both answer** — and adb then picks for
you silently. `export ANDROID_SERIAL=<serial>` (from `adb devices`) once per session; every adb
call and `drive.mjs` honours it. `flutter run` needs its own `-d <serial>`.

**Logcat capture** (save to scratchpad, never the repo):
```bash
adb logcat -c && adb logcat --pid=$(adb shell pidof -s com.hsrutility.arul) > <scratchpad>/capture.txt
```
`--pid` drops every other app's lines, so the 256 KiB ring buffer holds the window you care about
instead of evicting it. Take the pid from `pidof`, never from a `Start proc` log line. System-side
anchors (`ActivityTaskManager`, `CCodec`, `ANR in`) are emitted by OTHER pids — for those, capture
unfiltered (`adb logcat -G 16M` first) and grep.

Proven filters — grep the capture, don't eyeball:
| Problem | grep |
|---|---|
| PhonePe SDK failures | `PR004`, `B2bPgActivity`, `PG_PAY_V2`, `AutoPaySetup`, `[PremiumPurchase]` |
| Video/feed jank | `BLASTBufferQueue`, `ExoPlayer`, `FeedVideoPlugin`, `FeedVideo:`, `Choreographer.*Skipped` |
| Crashes/ANR | `FATAL`, `AndroidRuntime`, `ANR in` |
| Sign-in | `GoogleSignIn`, `ApiException`, `[ApiAuthService]` |
| Ad events (debug build) | GA4 `FA-SVC  : Logging event` (after `setprop log.tag.FA-SVC VERBOSE`), Meta `FacebookSDK.AppEvents: Created app event`, PostHog `PostHog : Queued Event` (Play-installer sideload: `adb install -i com.android.vending`) |

`Skipped` is capital-S in AOSP — a lowercase grep matches nothing. The app's own tags —
`FeedVideoPlugin`, `FeedVideo:`, `[ApiAuthService]`, `[PremiumPurchase]` (plain `debugPrint`),
`[boot]` (`kReleaseMode`-gated) — are all readable in **debug and profile**. Never grep
`VideoOutput` — that was media_kit's tag, and this app ships Media3 only.

**A release build is SILENT by design** (owner's call): `main()` reassigns
`debugPrint` to a no-op under `kReleaseMode`, so every Dart log — this app's and every package's —
is gone, and `-assumenosideeffects android.util.Log` strips Kotlin `v/d/i` (`w/e` are KEPT:
operational error diagnostics). So `--release` is the wrong build to debug on: grep it and you get
nothing, which reads exactly like a broken feature. Use **profile** (`--profile`) — AOT-true and
fully logged — or, when the release binary itself is the suspect, sideload one built with
`--dart-define=DIAG=true` to bring the Dart logs back (Kotlin `v/d/i` stay stripped — `DIAG` gates
only `debugPrint`). **A Play install shows only Kotlin `Log.w/e` and native/system lines** (`CCodec`,
`ActivityTaskManager: Displayed`, `MediaCodec`) — no Dart line, no `FeedVideoPlugin`/`FA` chatter;
beyond those, Crashlytics is the only diagnostic channel that reaches it.

Known-benign: `BLASTBufferQueue ... max frames` while the feed idles = compositor noise, 0 crashes — do NOT
chase it.

**Measuring speed on device** — frame timing, cold start, jank: read
[docs/perf-measurement.md](../../../docs/perf-measurement.md) FIRST. `dumpsys gfxinfo` reads 0
frames for a Flutter app, an idle feed scores ~70% "janky", and logcat's default buffer eats the
early `[boot]` marks — each of them cost real time once. Measure on a PROFILE build.

**Screenshots still work here.** `FLAG_SECURE` is applied only when the installer is
`com.android.vending`, so `flutter run` builds and sideloaded release APKs stay capturable
(`scrcpy`, `adb exec-out screencap`). A build installed *from Play* blanks screenshots, screen
recording and the recents thumbnail — driving that one visually is impossible; read logcat instead.
Raw bytes come back through `exec-out`, never `shell`: `adb shell` translates LF to CRLF and
corrupts a piped PNG or zip. `shell` acts on the device, `exec-out` streams from it.

**GA4 DebugView:** `adb shell setprop debug.firebase.analytics.app com.hsrutility.arul` → Firebase console → DebugView. Off: same command with `.none.` (trailing dot — that exact sentinel). Release builds have no DebugView, and the in-app `FA` tag is `Log.v/d` (R8-stripped, `DIAG` does not restore it) — in release only the Play-services side `FA-SVC` survives (docs/analytics-ops.md).

**Automate the loop — act by label, not screenshot.** Two layers, split by scope:

*In-app (the Dart MCP server from the `dart-flutter` plugin):* run with the driver
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
node tools/drive.mjs dump              # labels: DEBUG build, or ANY build with an a11y service on (below)
node tools/drive.mjs tap "Ringtones"   # substring match on text/content-desc; --index N on ties
node tools/drive.mjs swipe up          # fling the feed (down|left|right, --dist px, --ms n)
node tools/drive.mjs open "https://arul.hsrutility.com/w/<id>"   # deep link — skip the tapping
adb shell "am start -a android.intent.action.VIEW -d 'fb<META_APP_ID>://open?ringtone_id=<id>&lang=hi'"  # Meta form — INNER quotes or the phone's shell eats the &
node tools/drive.mjs wait "Set as wallpaper" --ms 15000   # poll, NEVER sleep — see below
node tools/drive.mjs wait-gone "Loading"                  # spinner cleared
node tools/drive.mjs wait-window phonepe                  # an OS/third-party surface took focus
node tools/drive.mjs current           # focused window: how you detect an OS surface on top
# also: tap x y · type · key back|wake|… · launch · stop · shot [path] · unlock
```
**Never `sleep N` between a tap and the next step.** A sleep that is long enough on your phone is
short on a cold Vivo and wasted on a warm Pixel; the `wait*` verbs return the instant the condition
holds and print what IS on screen when they time out, so a failure names its own cause. Sleep only
where nothing observable changes.

**Throttled and offline runs.** A flow that only ever ran on your Wi-Fi is untested: real installs
sit on Airtel/Jio 4G, and every pre-login timeout fires there first. Throttle the PHONE (Android 13+
"Network download rate limit"): `adb shell settings put global ingress_rate_limit_bytes_per_second
32000` (256 kbps; `8000` ≈ 2G), and `-1` to clear it — ALWAYS clear it after. It caps downloads on
Wi-Fi and cellular alike (uploads and latency untouched) and needs kernel support: the A001 held
30 KB/s on a 32000 cap. On another phone, time a known download first (the launch clip's `download
start` → `on disk`). Offline = `svc wifi disable` where mobile data carries no internet, else data
off too; assert `dumpsys connectivity` reads `Active default network: none`. Fallback without the
setting: the emulator's `adb emu network speed edge`, Wi-Fi off first (Wi-Fi is exempt there).

**Return page, no real mandate:** `DEBUG_RETURN_PAGE=on` (debug) opens it from any paywall; its button
toasts. Uncut clips: `DEBUG_RETURN_CLIP_DIR=/data/user/0/com.hsrutility.arul/files/return`, filled via
`/data/local/tmp` + `run-as … cp` — a file `adb push`ed into `/sdcard/Android/data/<pkg>/` is `EACCES`.

**Deferred deep links on a sideloaded build:** `DEBUG_INSTALL_REFERRER` / `DEBUG_DEFERRED_LINK` stand in
for Play's referrer replay and the GA4F/Meta fetch (debug only, once per install — `adb shell pm clear`
between runs). Pass them through a `--dart-define-from-file` JSON, never on the command line: an unquoted
`&` in a bare `--dart-define` splits the shell command. Recipes: docs/deferred-links.md. A release/profile build shows
NO
labels until an accessibility service is on (Flutter builds semantics only then): `adb shell settings put secure enabled_accessibility_services com.android.systemui.accessibility.accessibilitymenu/com.android.systemui.accessibility.accessibilitymenu.AccessibilityMenuService` + `settings put secure accessibility_enabled 1` → dump → `settings delete secure enabled_accessibility_services` + `accessibility_enabled 0`. A Play install is FLAG_SECURE as well: `shot` is black there, dump is not.

**Automation guard-rails.** dev.json points at the LIVE worker: a signed-in automated run writes
real rows, and every gated `action=apply` bumps public popularity ranking — keep loops off
Apply/Set on real accounts, and never drive a real PhonePe sheet (verify-payments is the harness
for that). Screenshots answer visual questions ONLY — a live card that hasn't decoded yet is
pixel-identical to a static one BY DESIGN; prove video from logcat (`FeedVideoPlugin`,
`FeedVideo: first frame revealed` — debug/profile; on a release build the native
`CCodec: Created component [c2.mtk.avc.decoder]` line is the only decode anchor), never from pixels.
