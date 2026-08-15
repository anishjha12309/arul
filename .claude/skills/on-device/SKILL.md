---
name: on-device
description: Run and debug Arul on a real Android device — flutter run with dart-defines, adb logcat capture, and the proven filters for PhonePe, video/surface, and analytics issues.
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

`Skipped` is capital-S in AOSP — a lowercase grep matches nothing. The app's own tags are the ones
that survive `--release`: `FeedVideoPlugin`, `FeedVideo:`, `[ApiAuthService]`, `[PremiumPurchase]`
(plain `debugPrint`). `[boot]` and the PhonePe wrapper's `phonepe_payment_sdk` are debug-only, so a
`--release` run emits neither. Never grep `VideoOutput` — that was media_kit's tag, and this app
ships Media3 only.

Known-benign: `BLASTBufferQueue ... max frames` while the feed idles = compositor noise, 0 crashes — do NOT chase it.

**Screenshots still work here.** `FLAG_SECURE` is applied only when the installer is
`com.android.vending`, so `flutter run` builds and sideloaded release APKs stay capturable
(`scrcpy`, `adb exec-out screencap`). A build installed *from Play* blanks screenshots, screen
recording and the recents thumbnail — driving that one visually is impossible; read logcat instead.

**Ringtone Set below Android 10** takes a different code path (public Ringtones dir + a runtime
`WRITE_EXTERNAL_STORAGE` prompt) than API 29+ — when touching Set, exercise BOTH paths: a modern
phone alone never executes the pre-Q branch.

**GA4 DebugView:** `adb shell setprop debug.firebase.analytics.app com.hsrutility.arul` → Firebase console → DebugView. Off: same command with `.none.` (trailing dot — that exact sentinel). Release builds have no DebugView — prove the upload path from logcat instead (docs/analytics-ops.md).

**Wallpaper-apply testing:** apply triggers an OS activity recreate — the `configChanges` fix must keep the app alive; a cold restart on apply = regression (docs/edge-cases.md).

**Video QC on budget devices:** watch for green edge strips on live cards (dimension rule violated or
software-decoder fallback — see docs/media-conventions.md) and for black cards (decoder budget).
