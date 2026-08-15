# Deep links

Read this when touching the URL a share or an ad carries, the App Links setup, or anything that turns
an incoming link into a wallpaper on screen. Share payload, caption and attribution rules are in
[share.md](share.md); the feed ordering it lands on is CLAUDE.md §5b.

`https://arul.hsrutility.com/w/<wallpaper-id>?ref=<code>` — built by
`InstallReferrerService.buildWallpaperLink`. The same URL is what goes in ad creatives.

One URL, two resolutions, and BOTH halves are required:

- **App installed** — Android verified the host at install time and intercepts before any browser, so
  `/w/:id` is never fetched. go_router's `/w/:id` route parks the id in `ArulDeepLink` and redirects to
  `/`; the feed consumes it once the catalog lands and jumps to it **on All** (the only chip that
  contains every row).
- **Not installed** — the Worker's `/w/:id` redirects to Play with `referrer=ref=<code>&w=<id>`, which
  Android replays to `InstallReferrerService` on first launch. That is what makes the WALLPAPER open
  after the install, not just the app.

Traps, all of which fail SILENTLY — nothing logs. The first three drop the link into a browser; the
last three keep the app but lose the wallpaper:

- [ ] `ANDROID_CERT_SHA256` must carry the cert **Play actually signed this build with**, not only the
      upload key — Play re-signs every AAB, so an upload-key-only file verifies on a local release APK
      and fails on every real install. **Ground truth is the device, not the Play Console page**
      (`adb shell pm get-app-links <pkg>`): the console's listed fingerprints were verified wrong on a
      real install. The var takes a comma-separated list; list every candidate.
- [ ] Four places must agree on the host: `kDeepLinkHost`, the manifest's `android:host`, the
      `wrangler.toml` custom domain, and whoever serves `/.well-known/assetlinks.json`.
- [ ] `flutter_deeplinking_enabled` meta-data must stay true, or the intent opens the app onto `/` with
      the id nowhere.
- [ ] The https filter must stay SEPARATE from the `arul://` one. An intent-filter matches the cross
      product of its schemes and hosts, so merging them registers `arul://arul.hsrutility.com` and puts
      the PhonePe return scheme under `autoVerify`.
- [ ] ONE level of encoding on `referrer`. Double-encoding hands the app a single key literally named
      `ref=CODE&w=<uuid>`, and both attribution and the deferred deep link stop working.
- [ ] The deferred target is seeded from BOTH `captureOnce` and the persisted pref (main.dart), because
      either can win the startup race against the feed's first catalog drain. Whoever consumes it clears
      the pref — consuming one without the other re-opens the wallpaper next launch.

An ad tapped inside Facebook/Instagram may load this URL in their in-app webview rather than handing
the OS an intent, in which case an installed user still lands on Play. The fix is not in this repo —
put the URL in the ad platform's deep-link field so the platform does the hand-off.

## Google Ads DDL — a THIRD delivery path, not a replacement

A Google App Campaign does NOT use the Play referrer above. GA4F fetches the ad group's App URL over
the network at app start and writes it to SharedPreferences `google.analytics.deferred.deeplink.prefs`
(key `deeplink`); `MainActivity` reads + listens, validates it is our `/w/<uuid>`, and hands it to the
same `pending_deeplink_wallpaper` one-shot. Opt-in is the `google_analytics_deferred_deep_link_enabled`
manifest meta-data. Contract + diagnostic recipe:
[Enable DDL in your measurement SDK](https://support.google.com/google-ads/answer/12373942) — read it
there, never from memory.

- [ ] **Delivery identity is the URL ALONE**, never url+`timestamp`. GA4F writes those two keys
      independently, so a composite token reads `0:<url>` on the launch that captures the link and
      `<bits>:<url>` once the timestamp lands — the handled marker stops matching and an
      already-consumed wallpaper re-opens on a later launch. (`timestamp` is also a Double stored as
      raw long bits: `getLong` then `Double.longBitsToDouble`, never `getFloat`/`getString`.)
- [ ] The App URL in the ad group must be **exactly** `https://arul.hsrutility.com/w/<uuid>`. Anything
      else is dropped at the native boundary and the install lands on the plain feed with nothing
      logged anywhere — the one hint is `W/MainActivity: Deferred deep link ignored` in logcat, and
      the shipped build is FLAG_SECURE so logcat is the only window.
- [ ] Native buffers the link and Flutter ACKs only after the id is **persisted**, so the ACK is the
      commit point; a process death before it re-delivers (at-least-once), and the feed's
      read-and-clear consume is what makes it exactly-once.
- [ ] `maybeOpenDeepLink` must stay re-checkable on every feed build. GA4F delivers mid-startup, so a
      once-per-mount flag drops the target for the whole session — and does the same to an App Link
      tapped while the app is already warm.
- [ ] Eligibility is narrow and account-side, so "the code is right" is not "it will fire": App
      campaigns **for installs** only, **AdMob and YouTube** inventory only, Android only, deep links
      must be **allowlisted** for feed-served dynamic ads, and the user must install AND open within
      **24 h** of the click. Nothing in this repo can widen any of that.
- [ ] Test without a live ad: register a diagnostic DDL against the device's AdID
      (`.../pagead/conversion/app/deeplink?…&ddl_test=1`, expires in 24 h), then
      `adb shell setprop debug.deferred.deeplink com.hsrutility.arul`. Logcat should show
      `D/FA: Deferred Deep Link feature enabled.` with `gmp_version` ≥ `18200`.
