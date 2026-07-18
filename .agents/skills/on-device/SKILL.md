---
name: on-device
description: Run and debug Arul on a real Android device — flutter run with dart-defines, adb logcat capture, and the proven filters for PhonePe, video/surface, and analytics issues.
---

# On-Device Run & Debug

**Run:** `adb devices` (must list one) → `flutter run --dart-define-from-file=env/dev.json`. Prod-config: `env/prod.json`. Release feel: add `--release`.

**Logcat capture** (save to scratchpad, never the repo):
```bash
adb logcat -c && adb logcat > <scratchpad>/capture.txt   # reproduce, then Ctrl-C
```

Proven filters — grep the capture, don't eyeball:
| Problem | grep |
|---|---|
| PhonePe SDK failures | `PR004`, `B2bPgActivity`, `PG_PAY_V2`, `AutoPaySetup` |
| Video/feed jank | `BLASTBufferQueue`, `VideoOutput`, `ExoPlayer`, `Choreographer.*skipped` |
| Crashes/ANR | `FATAL`, `AndroidRuntime`, `ANR in` |
| Sign-in | `GoogleSignIn`, `ApiException` |

Known-benign: `BLASTBufferQueue ... max frames` while the feed idles = compositor noise, 0 crashes — do NOT chase it.

**GA4 DebugView:** `adb shell setprop debug.firebase.analytics.app com.hsrapps.arul` → Firebase console → DebugView. Off: same command with `.none`.

**Wallpaper-apply testing:** apply triggers an OS activity recreate — the `configChanges` fix must keep the app alive; a cold restart on apply = regression (docs/edge-cases.md).

**Video QC on budget devices:** watch for green edge strips on live cards (dimension rule violated or
software-decoder fallback — see docs/media-conventions.md) and for black cards (decoder budget).
