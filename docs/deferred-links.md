# Deferred deep links — the not-installed half

Read this when an ad install lands on the plain feed, when touching `MainActivity`'s deferred bridge
or `DeferredLinkService`, or before buying ads. The URL shapes and the installed half:
[deep-links.md](deep-links.md). Three deliveries, one Dart handoff; NONE of them can be simulated
from inside this repo without the recipe under each.

## Shared bridge contract (`com.hsrutility.arul/deferred_link`)

- [ ] **Delivery identity is the URL ALONE.** Native keys its queue and its persisted `handled_tokens`
      set by the URL; Dart de-dups on the same token. For GA4F never url+`timestamp` (see below).
- [ ] Native buffers across the Flutter-engine startup race (`getDeferredDeepLinks` pull + an
      `onDeferredDeepLink` push per link) and Flutter ACKs only after `InstallReferrerService.queueRequest`
      has **persisted** the target — the ACK is the commit point; a process death re-delivers
      (at-least-once), the screens' read-and-clear consume makes it exactly-once.
- [ ] **Both sides validate**: native accepts `https://arul.hsrutility.com/{w,r}/<uuid>` (any query) or
      `fb<digits>://open…`; Dart re-parses and ACKs a rejected URL too, or native re-offers it on every
      Activity creation forever. A rejection logs `W/MainActivity … ignored` — the shipped build is
      FLAG_SECURE, so logcat is the only window on a misconfigured ad.
- [ ] `source` (`google_ads` / `meta`) rides through to `deep_link_opened` and to the persisted
      `pending_deeplink_source`, so a target restored after a process death still reports its channel.

## Play Install Referrer (a browser tap on `/w/` or `/r/` with no app)

The Worker 302s to Play with `referrer=ref=<code>&w=<uuid>&lang=hi` (or `r=<uuid>`); Android replays
it to `captureOnce` on first launch (Play keeps it 90 days, once per install — the `_kChecked` pref).
Proving it needs a Play install of THIS build: uninstall, then fire the REAL link on the phone —
`adb shell "am start -a android.intent.action.VIEW -d 'https://arul.hsrutility.com/r/<uuid>?lang=ta'"`
— with no app to claim the App Link it lands in Play's listing sheet with the referrer attached;
install from the testing track, launch, sign in. GA4F logs the referrer Play delivered
(`V/FA-SVC … InstallReferrer API result: r=<uuid>&lang=ta`, with `log.tag.FA-SVC VERBOSE`), and the
app's `deep_link_opened source=install_referrer` follows sign-in. A Play build is a release build:
read its screen per the on-device skill (a11y service on, dump, off). A sideloaded APK never
receives a referrer — use the seam instead.

## Google Ads DDL — GA4F fetches the ad group's App URL

Enabled by the `google_analytics_deferred_deep_link_enabled` manifest meta-data; GA4F writes the URL to
SharedPreferences `google.analytics.deferred.deeplink.prefs` (key `deeplink`), `MainActivity` listens
AND reads once. Contract + diagnostic recipe:
[Enable DDL in your measurement SDK](https://support.google.com/google-ads/answer/12373942) — read it
there, never from memory.

- [ ] GA4F writes `deeplink` and `timestamp` independently, so a composite token reads `0:<url>` on the
      capturing launch and `<bits>:<url>` once the timestamp lands — the handled marker stops matching
      and a consumed target re-opens later. (`timestamp` is a Double stored as raw long bits.)
- [ ] The ad group's App URL must be **exactly** `https://arul.hsrutility.com/w/<uuid>` or `/r/<uuid>`,
      `?lang=` allowed. Anything else is dropped at the native boundary.
- [ ] Eligibility is narrow and account-side: App campaigns **for installs** only, **AdMob and YouTube**
      inventory only, Android only, deep links **allowlisted** for feed-served dynamic ads, and the user
      must install AND open within **24 h** of the click. Nothing in this repo can widen any of that.
- [ ] Test without a live ad: register a diagnostic DDL against the device's AdID
      (`…/pagead/conversion/app/deeplink?…&ddl_test=1`, expires in 24 h), then
      `adb shell setprop debug.deferred.deeplink com.hsrutility.arul`. Logcat should show
      `D/FA: Deferred Deep Link feature enabled.` with `gmp_version` ≥ `18200`.

## Meta deferred — the FB SDK asks Meta once per install

Meta's Android deep-link doc (read in the browser 2026-08-26, page dated Apr 14 2026): deferred deep
linking needs the FB SDK, **Advertiser ID collection enabled** (manifest: on), and the deep link put in
the ad set's creative; the call is `AppLinkData.fetchDeferredAppLinkData(context) { data -> data?.targetUri }`.
`MainActivity.fetchMetaDeferredLink` runs it in `onCreate`.

- [ ] **It logs NO app event and touches NO SDK flag.** The reference apps' `flutter_facebook_app_links`
      plugin was rejected on purpose: its native `activateSDK()` calls
      `FacebookSdk.setAutoLogAppEventsEnabled(false)`, which would silence Meta's own install/launch
      attribution events. The SDK was initialised by its manifest ContentProvider before the Activity
      existed; a key-less build (`FacebookSdk.isInitialized()` false) skips the fetch.
- [ ] The SDK reports "no link" and "network failed" identically (a null callback), so the fetch retries
      on the next launches — **up to 3 attempts, persisted in `arul.deferred_link` prefs** — and stops
      the first time Meta answers with data (`meta_done`). The captured URL is persisted (`meta_link`)
      before it is enqueued, so a destroyed Activity re-offers it.
- [ ] Meta's own Install Referrer (the encrypted `utm_content` in Play's referrer) carries campaign
      metadata ONLY, never the deep link — do not go looking for the target there.
- [ ] Test: Meta App Ads Helper → "Test Deep Link" → the exact `fb<id>://open?…` (or https) URL →
      tick **Send Deferred** (not Send Notification) → "Send to Android"; Meta answers "queued,
      pending a first app launch". The Facebook app on the phone must be logged into the developer
      account. Then uninstall Arul, reinstall over adb, launch: `meta_done=true` + the URL inside
      `handled_tokens` (`arul.deferred_link` prefs) = delivered AND ACKed. A live-ad preview does
      NOT exercise it.

## The debug seams (sideloaded DEBUG builds only, compiled out of release)

```bash
# seam.json: {"DEBUG_INSTALL_REFERRER": "r=<uuid>&lang=ta"}   — stands in for Play's replay
#        or: {"DEBUG_DEFERRED_LINK": "fb<id>://open?wallpaper_id=<uuid>&lang=hi"} — for GA4F / Meta
flutter build apk --debug --split-per-abi --dart-define-from-file=env/dev.json --dart-define-from-file=seam.json
adb shell pm clear com.hsrutility.arul   # between runs: both seams are once-per-install like the real thing
```
A FILE, never `--dart-define=…&lang=…` on the command line: on Windows `flutter` is a `.bat`, and
cmd.exe treats an unquoted `&` as a command separator — the define arrives cut at `&`, the target opens
and `lang` silently never does (paid for 2026-08-26). They feed the SAME `queueRequest` the real
callbacks feed, so parse → persist → shell → screen → language runs end to end; only the network
fetch itself is skipped.
