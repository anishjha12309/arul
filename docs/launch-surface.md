# Launch surface — what the user sees before the feed

Read before touching `values/styles.xml`, `MainActivity.onCreate`, `VideoBackground`, the splash, or the
`flutter_native_splash` config. Two independent surfaces cover a cold start, and each was a separate
bare-screen bug. Measuring any of it: [perf-measurement.md](perf-measurement.md).

## 1. The OS launch theme — `windowSplashScreen*` is Android 12+ ONLY

`android:windowSplashScreenBackground` and friends **do nothing below API 31**: the OS falls back to
`android:windowBackground`, so older Android showed a bare flat rectangle for the entire cold start.
`androidx.core:core-splashscreen` backports the Android 12 splash below `minSdk`:

- `LaunchTheme` parents **`Theme.SplashScreen.IconBackground`** and sets `postSplashScreenTheme`
  (required) plus `windowSplashScreenAnimatedIcon`.
- `installSplashScreen()` runs in `MainActivity.onCreate` **before `super.onCreate()`** — after it, it
  is a no-op.
- The icon is `@mipmap/ic_launcher_foreground`, **not** `@mipmap/ic_launcher`: an
  `AdaptiveIconDrawable` resolves only from API 26, below `minSdk`.
- **Keep `values/` and `values-night/` identical** — the launch surface is dark in both themes.

**`values/styles.xml` is HAND-OWNED.** `flutter_native_splash:create` rewrites it and emits none of the
above, silently returning older Android to the flat rectangle. Re-apply the `LaunchTheme` block in BOTH
files after any regen (the warning sits beside the generator config in `pubspec.yaml`).

## 2. The Flutter shutter — `VideoBackground` holds artwork, not a colour

Once the OS splash hands off, the decoder has not produced a frame yet, and a flat colour there was a
second gap. `VideoBackground` holds `assets/images/splash_poster.webp` — **frame 0 of `splash.mp4`** —
under the raw `Texture`, the way Media3's `PlayerView` holds artwork behind its shutter. Because it is
that exact frame, the handoff needs no crossfade. It stays MOUNTED under the texture so a dropped decoder
never re-exposes bare colour. **Both fixes are required; neither is sufficient alone.**

## The splash's own decisions

- **The splash routes the moment the auth seed settles — NO fixed beat, and no timer floor may be
  re-added** (owner: the old delay measured as pure dead time).
- **`autoSignIn` stays BEFORE the `context.go`**: it sets `_autoLaunched` synchronously, so the sign-in
  screen's first-frame auto-launch JOINS that attempt instead of opening a second picker.
- **Splash media warm is AUTH-GATED.** Signed out, it warms ONE poster and ZERO live MP4 bytes — the full
  warm fighting Google's token mint, the Firebase id and `POST /auth/login` for one pipe WAS the slow
  first login. The feed's `VideoPreloadController` re-runs `prefetchAround` on mount.
- **The signed-out first second stays as it is: catalog drain, one poster, FCM registration and Meta's
  fetch all start at launch.** Holding them behind the credential was built and measured: Google's step
  and `/geo` moved within noise, push registration landed 9 s later and the feed's art later; the only
  gain was on a pathologically slow link. Never re-add a gate.
- **`GET /geo`'s timeout is 12 s, not 5** — there is no second ask in that launch, and a miss costs the
  first launch its language. The budget is for a slow LINK, never a slow Worker.
- **Only the `exp_regional` arm waits for `/geo`**, at most `regionCap` (1,200 ms from the ask, fresh
  install, first launch, signed out) and only AFTER `autoSignIn` fired, so Google's sheet is never held.
  Measure with the `[boot]` marks `geo: answered in` / `splash: region wait ended`; if the LTE p90
  passes the cap, LOWER the cap, never raise it.
- **The regional wall paints its final language and poster on its FIRST frame — never flip.** While
  waiting the splash shows ground + wordmark only (the tagline's language is unknown). At the cap
  `closeLiveWindow()` makes a late answer store-only (next launch), and `LaunchArtNotifier.settle()`
  fixes the poster once.
- **A 9:16 poster on a 9:20 phone crops only its sides, so alignment cannot lift a face** —
  `RegionalPoster.zoom` about `pivot` does; the framing is the owner's, judged by eye.
  `regional_wall_matrix_test.dart` gates type and clip-on-poster.
- **The poster's own live clip is a bonus, never the base.** It downloads (catalog row by `wallpaperId`,
  feed cache, never a bundled key) only after the wall painted AND Google's surface showed or settled —
  never signed in, on Data Saver or a poster-rule phone. It swaps onto the ONE shared auth player (never
  a second decoder) paused, fades in on frame 0 = the poster's pixels, then loops; a launch clip stays
  one deity for its whole loop. Any failure keeps the poster.

## The poster rule — who gets no auth video

`VideoBackground` asks `DeviceMemory.isLow` BEFORE acquiring the shared player, so no MediaCodec is ever
created for the splash or the wall on: the Android Go flag, under 4.5 GiB total RAM (every 4 GB phone
reports ~3.6, no 6 GB phone qualifies), or Android 12L (API 32) and older. **Never add the OS's `lowMemory`
pressure flag**: it is set at random on the cold start right after a Play install, so capable phones got
the poster by chance, first-sheet dismissals rose on exactly those tiers both times it shipped, and the
phones it touched cannot be identified in analytics. The probe fails OPEN to the video. Test the poster
path on a capable phone: sideload, `adb shell settings put global arul_force_low_ram 1`, force-stop (the
answer is cached per process), then `settings delete global arul_force_low_ram`. The override is gated
on `!isPlayInstall()`.

## The session seed

- **A TRUE FIRST LAUNCH skips the secure-storage read** — a fresh install cannot hold tokens, and that
  read pays keystore master-key setup that was the last thing gating the picker. Fail-safe: a process
  that never resolved the first-launch marker reads false and takes the keystore wait, so the picker
  can never fire over a signed-in user. Keep `warmSecureStorage` at the TOP of `main()`, **before
  Firebase** — serialising them re-adds real time.
- **A Keystore refusal moves the session to app-private storage.** Some Android 8.1/9 keymasters answer
  every key generation or load with `KeyStoreException: Memory allocation failed` (-41), RSA and AES,
  on every retry: sign-in succeeded, then the token write threw. No `AndroidOptions` cipher helps, and
  changing it migrates every healthy install. `ApiClient` switches to SharedPreferences (out of backup
  and transfer) on the first refusal and stays there for the install (`arul_keystore_refused`), so one
  session never splits across two stores; the non-fatal `keystore refused` counts them.
- **Any other secure-storage read that THROWS settles the seed as signed out.** An error escaping the
  seed failed `initialized`, the splash's await threw before its `context.go`, and the app sat on the
  splash forever. Never let the seed future complete with an error — nothing catches it.

## Dead ends — do not re-attempt

- **Un-awaiting `GoogleSignIn.instance.initialize()` buys nothing** — with `google-services.json` the
  native side is already up via Firebase's ContentProvider. It starts in `main()` and is awaited via
  `GoogleSignInInit.ready`, per the plugin's own example.
- **Deferring `Firebase.initializeApp()`** — a small slice of a cold start, and Firebase warns Analytics
  collects events before the app instance is configured, with ad-related data at risk. `trial_started`
  is the only Google Ads conversion source.
- **Shrinking the live-wallpaper masters to cut decode cost** — 1024×1824 is already below a modern
  screen and capped by the hardware decoder ([media-conventions.md](media-conventions.md)), so a smaller
  master upscales on every 1080p phone. Per-tier variants are the only correct shape, and they double
  the encode and storage pipeline.
