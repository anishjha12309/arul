# Launch surface — what the user sees before the feed

Read before touching `values/styles.xml`, `MainActivity.onCreate`, `VideoBackground`, or the
`flutter_native_splash` config. Two independent surfaces cover a cold start, and each one was a
separate bare-screen bug. Measuring any of it: [perf-measurement.md](perf-measurement.md).

## 1. The OS launch theme — `windowSplashScreen*` is Android 12+ ONLY

`android:windowSplashScreenBackground` and `IconBackgroundColor` are platform attrs that **do nothing
below API 31**. There the OS falls back to `android:windowBackground`, which was a `layer-list`
holding one flat colour — so Android 12+ got the icon on the crimson field and **older Android got a
bare ink rectangle for the entire cold start**, on a large minority of installs. Android's own
migration guide names this outcome: migrating "using the `SplashScreen` API directly" leaves
"Android 11 and earlier … exactly the same as before".

The fix is `androidx.core:core-splashscreen`, which backports the Android 12 splash well below the
app's own `minSdk`:

- `LaunchTheme` parents **`Theme.SplashScreen.IconBackground`** and sets `postSplashScreenTheme`
  (required by the library) plus `windowSplashScreenAnimatedIcon`.
- `installSplashScreen()` runs in `MainActivity.onCreate` **before `super.onCreate()`** — the library
  installs into the window before content exists; after `super` it is a no-op.
- The icon is `@mipmap/ic_launcher_foreground`, **not** `@mipmap/ic_launcher`: an
  `AdaptiveIconDrawable` only resolves from API 26 and this app's `minSdk` is below that.
- **Keep `values/` and `values-night/` identical** — the launch surface is dark in both themes.

**`values/styles.xml` is HAND-OWNED.** `flutter_native_splash:create` rewrites it and emits none of
the above, so a regen silently drops the backport and returns older Android to the flat rectangle.
The warning lives beside the generator config in `pubspec.yaml`; re-apply the `LaunchTheme` block in
BOTH files after any regen.

## 2. The Flutter shutter — `VideoBackground` must hold artwork, not a colour

Once the OS splash hands off, the splash and sign-in screens are up but the Media3 decoder has not
produced a frame. `VideoBackground` painted a flat colour until it did — a second brown gap *after*
the launch theme was fixed.

Media3's own UI guidance is to hold a placeholder until the first frame renders, then reveal;
`PlayerView` does this with artwork behind its shutter. This widget drives a raw `Texture`, so it
supplies the artwork itself: `assets/images/splash_poster.webp`, **frame 0 of `splash.mp4`**, 512×912
and about 15 KB. Because it is that exact frame the handoff needs no crossfade — a fade would invent
a transition the user would otherwise never see. It stays MOUNTED under the texture (the feed's live
cards already work this way) so a decoder that drops can never re-expose bare colour.

**Both fixes are required and neither is sufficient alone** — measured on a low-end device, the
brown-screen duration fell in two steps, to zero only once both were in.

## The splash's own decisions

- **Splash media warm is AUTH-GATED.** A signed-out session warms ONE poster and ZERO live MP4
  bytes; the full warm fighting the sign-in's own network calls (Google token mint, Firebase id,
  `POST /auth/login`) for one pipe WAS the slow first login, and Google's own credential step is
  slowest on entry-level phones. Nothing is lost: the feed's `VideoPreloadController` re-runs the
  full `prefetchAround` on mount. It runs INLINE, because with the brand beat gone its old post-frame
  `!mounted` bail warmed nothing.
- **Low-memory and old phones get the poster ONLY — no auth video player.** `VideoBackground` asks
  `DeviceMemory.isLow` BEFORE acquiring the shared player, so no MediaCodec is ever created for the
  splash or the sign-in screen. The native rule is three STABLE facts: the Android Go flag, under
  4.5 GiB total RAM (a 4 GB phone reports ~3.6, a 6 GB ~5.5, so every 4 GB phone qualifies and no
  6 GB phone does), and Android 12 and older. **Never add the OS's `lowMemory` pressure flag**: it is
  set at random on the cold start right after a Play install, so capable Android 13+ phones got the
  poster by chance, first-sheet dismissals rose on exactly those tiers both times it shipped, and the
  phones it touched cannot be identified in analytics. Everything under the RAM line or on Android
  12 and older is already on the poster, so the flag can only take video away from phones that
  need it to wait through Google's sheet. The probe fails OPEN to the video: a missing channel or
  a platform error must never leave a bare background. To test the poster path on a capable phone:
  sideload, `adb shell settings put global arul_force_low_ram 1`, force-stop (the answer is cached
  per process), then `settings delete global arul_force_low_ram`. The override is gated on
  `!isPlayInstall()` like the QA tools — armed on a Play build it does nothing, verified on device.
- **The splash routes the moment the auth seed settles. There is NO fixed beat, and no timer floor
  may be re-added** (owner's call — the old fixed delay measured as pure dead time and was most of
  the first-content gap).
- **`autoSignIn` must stay BEFORE the `context.go`**: it sets `_autoLaunched` synchronously, which is
  what makes the sign-in screen's first-frame auto-launch JOIN that attempt instead of opening a
  second picker.
- **The stored-session seed SKIPS the secure-storage read on a TRUE FIRST LAUNCH.** A fresh install
  cannot hold tokens, and that first read pays keystore master-key setup that was the last thing
  gating the account picker. It is fail-safe by construction: a process that never resolved the
  persisted first-launch marker reads false and takes the keystore wait, so the picker can never fire
  over a signed-in user. Keep `warmSecureStorage` at the TOP of `main()`, **before Firebase** —
  serialising them re-adds real time, and the post-login token write wants the keystore ready.

## Dead ends — do not re-attempt

- **Un-awaiting `GoogleSignIn.instance.initialize()` buys nothing.** With `google-services.json` the
  native side is already up via Firebase's ContentProvider before Dart runs. The call is started in
  `main()` and awaited via `GoogleSignInInit.ready` in the sign-in path — correct per the plugin's
  own example, and worth no measurable time. Do not "optimise" it again.
- **Deferring `Firebase.initializeApp()` off the startup path.** It is a small slice of a cold start,
  and Firebase's docs warn that Analytics "collects events very early in the app start up flow, in
  some occasions before the primary Firebase app instance has been configured", with ad-related data
  at risk. `trial_started` is the only Google Ads conversion source — the trade is bad.
- **Shrinking the live-wallpaper masters to cut decode cost.** 1024×1824 is already *below* a modern
  screen and is capped by the hardware-decoder limit ([media-conventions.md](media-conventions.md)),
  so a smaller master would upscale on every 1080p phone. Per-tier variants are the only correct
  shape, and they double the encode and storage pipeline for decode time, not bandwidth.
