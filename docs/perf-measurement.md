# Measuring speed on device — the traps

Read this before timing anything on a phone: every line below is a measurement that lied once and
cost real time. Targets and the last measured baseline live in memory `arul-growth-metrics` —
numbers rot, these traps do not. Running/driving the app itself: the **on-device skill**.

**Measure on a PROFILE build.** Debug numbers are JIT-inflated lies; release no-ops `BootTrace`
(`kReleaseMode`) and swaps to the release cert, whose Google client id does not pair with
`dev.json`. Profile = AOT truth + debug signing + `[boot]` marks + `debugPrint` alive.

- **`dumpsys gfxinfo` reports 0 frames for this app** — Flutter renders through its own
  Skia/Impeller pipeline, not HWUI, so it reads like a dead app. Frame timing comes from
  `dumpsys SurfaceFlinger --timestats -enable|-clear|-dump`; `--latency` is deprecated and returns
  all-zero rows on Android 16.
- **`presentToPresent` measures presentation CADENCE, not smoothness.** An idle feed presents at
  the live wallpaper's own ~30fps because nothing else asks for a frame — correct behaviour that
  scores **~70% "janky"** against a 90Hz vsync. A jank window must be motion-dominated: ~10 flings
  at a **250ms** gap. The same flings scored 16% with 1200ms gaps and ~1% without; only the second
  number means anything.
- **logcat's main ring buffer is 256 KiB** and evicts the early `[boot]` marks before you can read
  them, so the trace looks like it starts mid-`main()`. `adb logcat -G 16M` first.
- **Thermal state silently rewrites results** — ~40min of building/installing puts the device at
  `Thermal Status: 1`. Check `dumpsys thermalservice`, cool with the screen off, and measure both
  builds back-to-back, interleaved.
- **`FeedVideo: prefetch look-ahead staged` fires once per PROCESS**, so it cannot time a re-login;
  there the oracle is the first `FeedVideo: first frame revealed` AFTER `POST /auth/login done`
  (the sign-in screen's own background video emits the same line).

## Comparing a Play install against a sideloaded build (2026-08-24)

- **Both must be measured with SYSTEM-SIDE anchors**, because a Play/release build is silent: `am start -W`
  (`TotalTime`, `LaunchState`), `ActivityTaskManager: Displayed`, native `CCodec: Created component
  [c2.mtk.avc.decoder]` (ALOG, survives R8 — decoder #1 is the splash/sign-in background video,
  decoder #2 is the feed pool mounting), `dumpsys meminfo` (PSS + `Graphics`), `top -b -n 1`,
  SurfaceFlinger timestats, `/proc/net/dev` (`/sys/class/net/*/statistics` is permission-denied).
- **The Play build and a sideloaded release carry different signing certs** (Play App Signing), so the
  swap is uninstall → install: pull the Play splits first (`pm path` → `adb pull`,
  `adb install-multiple` restores) and expect to sign in again — measurements need a signed-in feed.
- **Never cool the device with the screen off.** `KEYCODE_SLEEP` re-arms the PIN keyguard;
  `wm dismiss-keyguard` cannot pass a PIN, and the harness then measures the notification shade
  (8ms p95 at 120Hz, `LaunchState: UNKNOWN`, 0 decoders) while looking healthy. Cool with
  `am force-stop` + idle on the launcher, and set `settings put global stay_on_while_plugged_in 7`.
  Assert `mCurrentFocus` contains the package after every launch, and `cmd statusbar collapse` first.
- Take the pid from `pidof`, not the `Start proc` log line — the line is missed when logcat was
  cleared a beat late, and then every per-pid filter silently returns zero.
- **PSS is ~70% `Graphics`** (decoder output pools for the 3-player window + textures); Java heap is
  <20 MB. Trimming Dart objects moves nothing — only decoder count / buffer geometry does.
- `top` on an idle live feed reads ~25% (raster ~26% of a core + main ~7%): every 30fps video frame
  re-rasterises the whole scene (Impeller has no picture cache). Not a bug; the lever is scene cost.

## Cold-start comparison traps (2026-08-29)

- **NEVER quote a PROFILE cold start as a user-facing number.** Same vivo 1916, same source:
  profile `am start -W` = **4.9–5.1 s**, release = **1.24 s** (pm-clear cold) / 0.91 s (force-stop).
  A profile build left on a test phone was read as "the app takes 5 s to reach the account picker"
  and sent a whole session chasing a blocker that release does not have. Release, that phone,
  launch → Google account picker is **~2.2 s**.
- **`[boot]` marks DO NOT reach logcat on the vivo 1916 (Android 9, Funtouch).** A full cold-start
  capture yields ~65 lines total — the ROM suppresses app logging, `-s flutter:V` included, while
  native `Log.e` still lands. The on-device skill's "readable in debug and profile" holds on
  Android 16 (20/20 launches), not here. On that device use system anchors only; take the Dart-side
  phase breakdown from a modern phone and scale it.
- **A/B a change INTERLEAVED, never build-A-then-build-B.** Sequential runs let Play Services warm
  across the boundary and hand the second build a free win: BEFORE 2613 ms vs AFTER 1403 ms
  sequentially, which reversed to 3366 vs 2720 once interleaved run-by-run. The picker metric's
  spread (2.6–5.4 s) cannot resolve anything at n=10 — use `tap → app foreground` (±3%) instead.
- **APK file size is not APK content.** AGP's incremental packaging (zipflinger) rewrites in place
  and leaves the vacated bytes as a hole: a 15 KB asset addition produced a 12 MB larger file, all
  of it one gap before `lib/arm64-v8a/libdartjni.so`. Diff the sum of `compress_size` over the zip
  entries, not `ls -l`.
