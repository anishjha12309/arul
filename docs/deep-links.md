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

Traps, all of which fail SILENTLY (the link just opens a browser, nothing logs):

- [ ] `ANDROID_CERT_SHA256` must carry the **Play App Signing** cert, not only the upload key. Play
      re-signs every AAB, so an upload-key-only file verifies on a local release APK and fails on every
      real install.
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
