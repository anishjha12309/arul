# Launch surface — what the user sees before the feed

Read before touching `values/styles.xml`, `MainActivity.onCreate`, `VideoBackground`, or
`flutter_native_splash` config. Two independent surfaces cover a cold start, and each one was a
separate bare-screen bug.

## 1. The OS launch theme — `windowSplashScreen*` is Android 12+ ONLY

`android:windowSplashScreenBackground` / `IconBackgroundColor` are platform attrs that **do nothing
below API 31**. There the OS falls back to `android:windowBackground`, which was
`@drawable/launch_background` — a `layer-list` holding one flat colour. So Android 12+ got the icon
on the crimson field and **API ≤30 got a bare ink rectangle for the entire cold start**, on ~28% of
installs. Android's own migration guide names this exact outcome: migrating "using the SplashScreen
API directly" leaves "Android 11 and earlier ... exactly the same as before".

The fix is `androidx.core:core-splashscreen`, which backports the Android 12 splash to API 23+:

- `LaunchTheme` parents **`Theme.SplashScreen.IconBackground`** and sets `postSplashScreenTheme`
  (required) plus `windowSplashScreenAnimatedIcon`.
- `installSplashScreen()` runs in `MainActivity.onCreate` **before `super.onCreate()`** — the
  library installs into the window before content exists; after `super` it is a no-op.
- The icon is `@mipmap/ic_launcher_foreground`, **not** `@mipmap/ic_launcher`: an
  `AdaptiveIconDrawable` only resolves from API 26 and `minSdk` here is 24.
- Keep `values/` and `values-night/` identical — the launch surface is dark in both themes.

**`values/styles.xml` is HAND-OWNED.** `flutter_native_splash:create` rewrites it and emits none of
the above, so a regen silently drops the backport and returns API ≤30 to the flat rectangle. The
warning lives beside the generator config in `pubspec.yaml`; re-apply the `LaunchTheme` block in
BOTH files after any regen.

## 2. The Flutter shutter — `VideoBackground` must hold artwork, not a colour

Once the OS splash hands off, the splash and sign-in screens are up but the Media3 decoder has not
produced a frame. `VideoBackground` painted flat `ArulColors.ink` until it did — a second brown gap
(measured 900 ms on the vivo 1916) *after* the launch theme was fixed.

Media3's own UI guidance is to hold a placeholder until the first frame renders, then reveal;
`PlayerView` does this with artwork behind its shutter. This widget drives a raw `Texture`, so it
supplies the artwork itself: `assets/images/splash_poster.webp` — **frame 0 of `splash.mp4`**,
512×912, ~15 KB. Because it is that exact frame, the handoff needs no crossfade; a fade would invent
a transition the user would otherwise never see. It stays MOUNTED under the texture (the feed's live
cards already work this way) so a decoder that drops can never re-expose bare colour.

Both fixes are required and neither is sufficient alone — measured on the vivo 1916, brown-screen
duration: **5400 ms → 900 ms (splash only) → 0 ms (both)**.

## Dead ends — do not re-attempt

- **Un-awaiting `GoogleSignIn.instance.initialize()` buys nothing.** It measures **0 ms**
  (`[boot]` marks, Android 16): with `google-services.json` the native side is already up via
  Firebase's ContentProvider before Dart runs. The call is now started in `main()` and awaited via
  `GoogleSignInInit.ready` in the sign-in path — correct per the plugin's own example, worth no
  measurable time. Do not "optimise" it again.
- **Deferring `Firebase.initializeApp()` off the startup path.** It is 161 ms of a 2107 ms cold
  start, and Firebase's docs warn that Analytics "collects events very early in the app startup
  flow, sometimes before the primary Firebase app instance has been configured" and that
  ad-related data can be missed. `trial_started` is the only Google Ads conversion source — the
  trade is bad.
- **Shrinking the live-wallpaper masters to cut decode cost.** 1024×1824 is already *below* a
  1080×2392 screen and is capped by the 1088×1920 hw-decoder limit (CLAUDE.md §8.1). A 768-wide
  master would upscale ~40% on every 1080p phone. Per-tier variants are the only correct shape,
  and they double the encode/storage pipeline for decode time, not bandwidth.
