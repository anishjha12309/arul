# Measuring speed on device — the traps

Read this before timing anything on a phone: every line below is a measurement that lied once and
cost real time. Running and driving the app itself: the **on-device skill**.

**Measure on a PROFILE build.** Debug numbers are JIT-inflated lies; release no-ops `BootTrace`
(`kReleaseMode`) and swaps to the release cert, whose Google client id does not pair with `dev.json`.
Profile = AOT truth + debug signing + `[boot]` marks + `debugPrint` alive.

## Instruments that lie

- **`dumpsys gfxinfo` reports 0 frames for this app** — Flutter renders through its own
  Skia/Impeller pipeline, not HWUI, so it reads like a dead app. Frame timing comes from
  `dumpsys SurfaceFlinger --timestats -enable|-clear|-dump`; `--latency` is deprecated and returns
  all-zero rows on recent Android.
- **`presentToPresent` measures presentation CADENCE, not smoothness.** An idle feed presents at the
  live wallpaper's own ~30 fps because nothing else asks for a frame — correct behaviour that scores
  around **70% "janky"** against a 90 Hz vsync. A jank window must be motion-dominated: about ten
  flings at a **250 ms** gap. The same flings scored 16% at 1200 ms gaps and ~1% without; only the
  tight-gap number means anything.
- **logcat's main ring buffer is 256 KiB** and evicts the early `[boot]` marks before you can read
  them, so the trace looks like it starts mid-`main()`. `adb logcat -G 16M` first.
- **Thermal state silently rewrites results** — about forty minutes of building and installing puts
  the device at `Thermal Status: 1`. Check `dumpsys thermalservice`, cool it, and measure both builds
  back-to-back, interleaved.
- **`FeedVideo: prefetch look-ahead staged` fires once per PROCESS**, so it cannot time a re-login;
  there the oracle is the first `FeedVideo: first frame revealed` AFTER `POST /auth/login done` (the
  sign-in screen's own background video emits the same line).
- **APK file size is not APK content.** AGP's incremental packaging rewrites in place and leaves the
  vacated bytes as a hole — a 15 KB asset addition once produced a 12 MB larger file, all of it one
  gap. Diff the sum of `compress_size` over the zip entries, not `ls -l`.

## Comparing a Play install against a sideloaded build

- **Both must be measured with SYSTEM-SIDE anchors**, because a Play/release build is silent:
  `am start -W` (`TotalTime`, `LaunchState`), `ActivityTaskManager: Displayed`, the native
  `CCodec: Created component` line (ALOG, survives R8 — decoder #1 is the splash/sign-in background
  video, decoder #2 is the feed pool mounting), `dumpsys meminfo` (PSS + `Graphics`), `top -b -n 1`,
  SurfaceFlinger timestats, and `/proc/net/dev` (`/sys/class/net/*/statistics` is permission-denied).
- **The Play build and a sideloaded release carry different signing certs**, so the swap is uninstall
  → install: pull the Play splits first (`pm path` → `adb pull`, `adb install-multiple` restores) and
  expect to sign in again — measurements need a signed-in feed.
- **Never cool the device with the screen off.** `KEYCODE_SLEEP` re-arms the PIN keyguard,
  `wm dismiss-keyguard` cannot pass a PIN, and the harness then measures the notification shade while
  looking perfectly healthy. Cool with `am force-stop` plus idle on the launcher, and set
  `settings put global stay_on_while_plugged_in 7`. Assert `mCurrentFocus` contains the package after
  every launch, and `cmd statusbar collapse` first.
- Take the pid from `pidof`, not the `Start proc` log line — that line is missed when logcat was
  cleared a beat late, and then every per-pid filter silently returns zero.
- **PSS is roughly 70% `Graphics`** (decoder output pools for the player window, plus textures); the
  Java heap is small. Trimming Dart objects moves nothing — only decoder count and buffer geometry
  do.
- `top` on an idle live feed reads around 25% of a core: every 30 fps video frame re-rasterises the
  whole scene (Impeller has no picture cache). Not a bug; the lever is scene cost.

## Cold-start comparison traps

- **NEVER quote a PROFILE cold start as a user-facing number.** On the same phone and the same
  source, a profile `am start -W` ran roughly four times the release figure. A profile build left on
  a test phone was read as "the app takes 5 s to reach the account picker" and sent a whole session
  chasing a blocker that release does not have.
- **`[boot]` marks do not reach logcat on every ROM.** Some vendor ROMs suppress app logging
  entirely, `-s flutter:V` included, while native `Log.e` still lands — a full cold-start capture
  yields a few dozen lines. On such a device use system anchors only, and take the Dart-side phase
  breakdown from a modern phone.
- **A/B a change INTERLEAVED, never build-A-then-build-B.** Sequential runs let Play Services warm
  across the boundary and hand the second build a free win — a comparison that looked decisive
  sequentially reversed once interleaved run by run. The account-picker metric's spread cannot
  resolve anything at n=10; use `tap → app foreground` instead.
