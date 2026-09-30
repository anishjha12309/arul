# Launch surface — what the user sees before the feed

Read before touching `values/styles.xml`, `MainActivity.onCreate`, `LaunchBackdrop`, the splash, or the
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

## 2. The Flutter shutter — the poster holds artwork, not a colour

Once the OS splash hands off, the decoder has not produced a frame yet, and a flat colour there was a
second gap. `LaunchBackdrop` paints the region's poster — **frame 0 of that deity's catalog clip** — under the
clip's `Texture`, the way Media3's `PlayerView` holds artwork behind its shutter, and it stays MOUNTED
there so a dropped decoder never re-exposes bare colour. **Both fixes are required; neither is sufficient
alone.** A re-cut clip means a re-cut poster from its new frame 0.

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
- **`GET /geo` never reads the keystore (`withToken: false`).** The secure-storage plugin runs every
  call in order on ONE thread, so a token read queued `/geo` behind `main()`'s first keystore read
  (~3 s on a vivo 1916) and only 5–12% of fresh installs got their region inside the cap.
- **On a fresh install `/geo` IS the warm-up** (`GeoRegionService.willAsk`): a second handshake to the
  same host beside it slows both on a slow link. Its time feeds `firstWarmUpMs`, which the launch
  clip's slow-link check reads.
- **`GET /geo`'s timeout is 12 s, not 5** — there is no second ask in that launch. The budget is for a
  slow LINK, never a slow Worker.
- **The splash waits for `/geo` only on a fresh install**, at most `regionCap` (from the ask, first launch,
  signed out) and only AFTER `autoSignIn` fired, so Google's sheet is never held. Set the
  cap from the field `geo_ms` p90; `[boot]` marks `geo: answered in` / `splash: region wait ended`.
- **Every install gets the regional wall** (the A/B ended; the lotus is retired). The kill switch
  `feature_flags.exp_regional = false` skips the region and its wait and shows Murugan with no clip.
- **The wall paints its final poster on its FIRST frame — never flip.** A miss settles on Murugan; `LaunchArtNotifier.settle()` fixes the poster once and a late answer only serves the next
  launch. The region never changes the language ([deep-links.md](deep-links.md)).
- **A 9:16 poster on a 9:20 phone crops only its sides, so alignment cannot lift a face** —
  `RegionalPoster.zoom` about `pivot` does; the framing is the owner's, judged by eye.
  `regional_wall_matrix_test.dart` gates type and clip-on-poster.
- **The poster's own live clip is a bonus, never the base.** Every deity's downloads (its
  `launchClipKey` cut, else the catalog row by `wallpaperId`; feed cache) only after the wall painted AND Google's surface showed
  or settled — never signed in, on Data Saver, a poster-rule phone or a slow link — so neither bytes nor
  a decode compete with the sheet's launch. It swaps onto the ONE shared auth player (never a second
  decoder) paused, fades in on frame 0 = the poster's pixels, then loops; a launch clip stays one deity
  for its whole loop. Any failure keeps the poster.

## The poster rule — who gets no auth video

`LaunchClip` asks `DeviceMemory.isLow` BEFORE any clip reaches the shared player, so no MediaCodec is ever
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

- **SharedPreferences, the Play-install probe and `GoogleSignInInit.start` begin BEFORE
  `Firebase.initializeApp`** (`_startEarlyHops`) and are awaited where they were: in series they sat
  ~250 ms between `main()` and the sheet request.
- **The tz database parse runs after the notification plugin's first Binder hop.** Push registration
  calls `initialize()` the instant the auth seed settles, ahead of the splash's own continuation, so a
  synchronous parse there ran before the sheet was requested.
- **The launch clip skips a slow link** — the splash warm-up over 1.5 s, or a metered link whose modem
  estimate is under 2 Mbps (`wall_clip=slow_link`): its MBs land while Google mints the token and our
  POST is in flight. The dev-options download cap slows neither reading much; real 2G slows both.

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
