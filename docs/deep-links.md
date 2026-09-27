# Deep links

Read when touching the URL a share or an ad carries, the App Links / Meta-scheme setup, or anything that
turns an incoming link into a wallpaper, a ringtone or a language. Share payload:
[share.md](share.md) · the not-installed deliveries and their test recipes:
[deferred-links.md](deferred-links.md) · the order a link lands on: [browse.md](browse.md).

## The two shapes the ad team pastes (nothing else is supported)

| Platform | Wallpaper | Ringtone | Language only |
| --- | --- | --- | --- |
| Google Ads · WhatsApp · any browser | `https://arul.hsrutility.com/w/<uuid>?lang=hi` | `…/r/<uuid>?lang=ta` | `…/w/?lang=hi` |
| Meta deep-link field | `fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi` | `fb<META_APP_ID>://open?screen=ringtones&ringtone_id=<uuid>&lang=hi` | `fb<META_APP_ID>://open?lang=hi` |

`lang` ∈ `en ta te kn ml hi` (region tags and case tolerated, anything else dropped); `?ref=<code>` rides
the https form for referral credit; **`ilang=` is SHARE-only — an ad must never carry it**
([share.md](share.md)). Keep the id-less form's TRAILING SLASH (`/w/`), matching the manifest's
pathPrefix, or an installed phone opens a browser while an uninstalled one reaches Play. Build https
links with `InstallReferrerService.buildWallpaperLink`/`buildRingtoneLink`, never by hand; the Meta
scheme reuses the `META_APP_ID` the SDK meta-data is baked from, so it cannot drift. The scheme form
needs App Dashboard → Settings → Android (package `com.hsrutility.arul`, class `…arul.MainActivity`).
`screen=` alone opens the tab; an id implies its tab.

## One URL, many deliveries, ONE parser, one slot

Every path ends in `ArulDeepLink` (`deep_link_target.dart`): a target plus a language, each consumed
once by the surface that can act on it — the shell picks the dock branch, the feed jumps to the
wallpaper **on All**, the Ringtones tab scrolls the row to the **top of All**, and `DeepLinkLocaleSync`
(above `MaterialApp`) applies the language live.

| App state | Delivery | Enters at |
| --- | --- | --- |
| Installed | https App Link (verified host) or `fb<id>://open?…` | go_router top-level `redirect` (the FULL intent URI) |
| Not installed, browser | Worker `/w/:id` · `/r/:id` → **200 bounce page, never a 302** → Play `referrer=` | `InstallReferrerService.captureOnce` |
| Not installed, Google App campaign | GA4F deferred deep link | `MainActivity` → `DeferredLinkService` |
| Not installed, Meta ad | `AppLinkData.fetchDeferredAppLinkData` | same bridge, `source=meta` |

A **campaign push** delivers into the same slot with no URL: `CategoryLinkTarget` and
`PremiumLinkTarget` exist for it alone, stamped `DeepLinkSource.push` so `deep_link_opened` never
reports a push as an ad click ([push.md](push.md)). Its handler selects the category BEFORE routing,
so the feed's first build already filters — routing first flashes the previous chip. `deep_link_opened`
fires on every landing and is GA4-only.

## Language precedence

**An explicit pick > the link > the REGION (fresh installs, once) > the phone > English.** A link's
language always wins over an earlier pick (owner) because it goes through `LocaleNotifier.setLocale`,
which PERSISTS — it is an explicit pick from then on, and Settings shows it.

- **The region is read ONCE per install.** Only a fresh install's first process sets
  `arul_geo_pending`; the splash asks `GET /geo` beside the warm-up, again each cold start until an
  answer lands, then never — an update never asks, so no existing install is re-languaged. The answer
  lives in `arul_geo_lang`, BESIDE `arul_locale`, never in it: Settings never shows a guess as a choice.
- Only India maps (`routes/geo.ts`), and `regionCode` is scoped to its country — `US`+`TN` is Tennessee.
  Delhi, Maharashtra and Gujarat stay unmapped by decision: Delhi's language switchers pick South Indian
  languages more often than Hindi.
- `GEO_LANG_ENABLED` (`[vars]`) is the brake — anything but `"true"` answers `lang: null` while `region`
  keeps flowing. A bare `/geo` also gets `lang: null`; only `?v=2` earns one, so fielded builds that
  apply `lang` unconditionally never leak it into the factorial's cohorts. The app applies `lang` only
  in the `exp_regional` arm; the control arm stores the region and keeps the phone
  ([launch-surface.md](launch-surface.md)).
- **Cloudflare's state accuracy on Indian carriers is unmeasured** — its database is not PostHog's
  MaxMind — and **the network path changes the answer**: on Jio the app read Delhi over IPv4 while a
  browser on the same phone that minute read Haryana over IPv6. Judge the app by its own reading
  (`npx wrangler tail arul-api --format json`, `cf.regionCode` on `/geo`), never a browser.
- No region answer → the phone's locale list, first supported LANGUAGE (`ta-MY` is Tamil). **That
  fallback is never written to `arul_locale`**: persisting it would freeze the app to the first launch's
  phone language and show a choice nobody made. Every screen that names the current language reads the
  resolved value, never the stored one.

## Traps — all fail SILENTLY

The first four drop the link into a browser; the rest keep the app but lose the target.

- [ ] **The cert list must carry the cert Play actually signed this build with** — Play re-signs every
      AAB, so an upload-key-only value verifies on a local release APK and fails on every real install.
      **Ground truth is the device** (`adb shell pm get-app-links <pkg>`), not the Console page, whose
      fingerprints were wrong once. The value is the deployed SECRET `ANDROID_CERT_SHA256`, not the dead
      toml key ([known-issues.md](known-issues.md)).
- [ ] Four places agree on the host: `kDeepLinkHost` (`deep_link_parser.dart`), the manifest's
      `android:host`, the `wrangler.toml` route, and whoever serves `/.well-known/assetlinks.json`.
- [ ] `flutter_deeplinking_enabled` stays true, or the intent opens the app onto `/` with the URI
      nowhere.
- [ ] **Intent-filters are never merged across schemes** — a filter matches the cross product of its
      schemes and hosts, so merging registers `fb…://arul.hsrutility.com` and puts a custom scheme under
      `autoVerify`. Four filters: `arul://` (the PhonePe return), one autoVerify filter each for `/w/` and
      `/r/`, and `fb${facebookAppId}://open`.
- [ ] The top-level `redirect` returns null for every scheme-less location (it runs on EVERY
      navigation) and `/` for every foreign-scheme URI, parseable or not — a typo'd ad link lands on the
      app, never on go_router's error page. It parks the target BEFORE the location becomes `/`, because
      the feed is reached only through the splash's auth decision.
- [ ] **ONE level of encoding on `referrer`** — double-encoding hands the app one key literally named
      `ref=CODE&w=<uuid>`. The six codes are duplicated in the Worker (`LANG_RE`), and so is the
      NORMALISATION: lower-case and strip the region tag exactly as `normalizeLang` does, or `hi-IN` is
      Hindi for an installed user and the phone language for a fresh install.
- [ ] The deferred target AND language are seeded from BOTH the capture and the persisted prefs — either
      can win the startup race against the first catalog drain. Whoever consumes clears the pref.
- [ ] **Typed takes:** the feed builds BEFORE the shell switches tabs, so `consumeWallpaper()` never eats
      a pending ringtone, nor the reverse. Both screens re-check on every build AND listen to
      `ArulDeepLink.changes` — an offstage screen gets no build otherwise.
- [ ] The ringtone scroll is arithmetic (`index × (RingtoneRow.extent + gap)`); a row that could grow
      taller than `extent` puts the wrong ringtone on top.
- [ ] A key-less dev build registers a bare `fb` scheme, which nothing sends. Fine, not a bug.

An ad tapped inside Facebook or Instagram may load the https URL in their webview, so an installed user
still lands on Play. The fix is not in this repo: put the URL (or the scheme form) in the ad platform's
deep-link field so the platform does the hand-off.

## Proving the installed half on a device

```bash
adb shell "am start -a android.intent.action.VIEW -d 'https://arul.hsrutility.com/r/<uuid>?lang=ta'"
adb shell "am start -a android.intent.action.VIEW -d 'fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi'"
```

**The inner quotes are load-bearing**: an unquoted `&` is a background operator to the PHONE's shell, so
the target opens and `lang` silently never arrives. A debug-signed build cannot verify the host
(assetlinks lists release certs only); force it with
`adb shell pm set-app-links --package com.hsrutility.arul 2 arul.hsrutility.com`.
