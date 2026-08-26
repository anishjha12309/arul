# Deep links

Read this when touching the URL a share or an ad carries, the App Links / Meta-scheme setup, or
anything that turns an incoming link into a wallpaper, a ringtone or a language on screen. Share
payload + caption: [share.md](share.md). The three deferred (post-install) deliveries and their
test recipes: [deferred-links.md](deferred-links.md). Feed order it lands on: CLAUDE.md §5b.

## The two shapes the ad team pastes (nothing else is supported)

| Platform | Wallpaper | Ringtone |
| --- | --- | --- |
| Google Ads App URL · WhatsApp share · any browser | `https://arul.hsrutility.com/w/<uuid>?lang=hi` | `https://arul.hsrutility.com/r/<uuid>?lang=ta` |
| Meta deep-link field (Facebook / Instagram) | `fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi` | `fb<META_APP_ID>://open?screen=ringtones&ringtone_id=<uuid>&lang=hi` |

`lang` ∈ `en ta te kn ml hi` (region tags and case are tolerated, anything else is dropped);
`?ref=<code>` still rides on the https form for referral credit. Build the https ones with
`InstallReferrerService.buildWallpaperLink` / `buildRingtoneLink`, never by hand. The Meta scheme
uses the SAME `META_APP_ID` the SDK meta-data is baked from (`env/prod.json`), so it cannot drift.
Meta also accepts the https form in its deep-link field (Meta doc, Apr 2026: App Links need no
dashboard work) — the scheme form needs App Dashboard → Settings → Android: package
`com.hsrutility.arul`, class `com.hsrutility.arul.MainActivity`. `screen=` alone just opens the tab;
an id implies its tab. The parser accepts the query keys on both hosts (`deep_link_parser.dart`).

## One URL, five deliveries, ONE parser, one slot

Every path ends in `ArulDeepLink` (`deep_link_target.dart`): a target (wallpaper · ringtone · tab)
plus a language, each consumed exactly once by the surface that can act on it — the shell picks the
dock branch (peek only), the feed jumps to the wallpaper **on All**, the Ringtones tab scrolls the row
to the **top of All**, `DeepLinkLocaleSync` (above `MaterialApp`) applies the language live.

| App state | Delivery | Where it enters |
| --- | --- | --- |
| Installed | https App Link (verified host) | go_router top-level `redirect` — Android hands Flutter the FULL intent URI |
| Installed | `fb<id>://open?…` from the FB/IG apps | same redirect; go_router normalises the empty path to `/` |
| Not installed, browser tap | Worker `/w/:id` · `/r/:id` → Play `referrer=ref=…&w=<uuid>&lang=hi` (`r=` for ringtones) | `InstallReferrerService.captureOnce` |
| Not installed, Google App Campaign | GA4F deferred deep link | `MainActivity` → `DeferredLinkService` |
| Not installed, Meta ad | `AppLinkData.fetchDeferredAppLinkData` | same bridge, `source=meta` |

**The link's language ALWAYS wins** (owner's call, 2026-08-26) — over the device default and over a
language the user picked in Settings; it goes through `LocaleNotifier.setLocale`, so Settings shows
it as the current choice. GA4-only event `deep_link_opened` (`kind`, `source`, id) fires on every
landing; it is deliberately NOT on the PostHog allow-list and not a Meta ★ event
([analytics-events.md](analytics-events.md)).

Traps, all of which fail SILENTLY — nothing logs. The first four drop the link into a browser; the
rest keep the app but lose the target:

- [ ] `ANDROID_CERT_SHA256` must carry the cert **Play actually signed this build with**, not only the
      upload key — Play re-signs every AAB, so an upload-key-only file verifies on a local release APK
      and fails on every real install. **Ground truth is the device, not the Play Console page**
      (`adb shell pm get-app-links <pkg>`): the console's listed fingerprints were verified wrong on a
      real install. The var takes a comma-separated list; list every candidate.
- [ ] Four places must agree on the host: `kDeepLinkHost` (`deep_link_parser.dart`), the manifest's
      `android:host`, the `wrangler.toml` custom domain, and whoever serves `/.well-known/assetlinks.json`.
- [ ] `flutter_deeplinking_enabled` meta-data must stay true, or the intent opens the app onto `/` with
      the URI nowhere. Verified against the engine jar (2026-08-26): the embedding passes
      `intent.data.toString()` — scheme, host and query intact — both cold and via `onNewIntent`.
- [ ] THREE intent-filters, never merged: `arul://` (PhonePe return), the https App Link (`/w/` and
      `/r/` are two `<data>` elements in ONE filter), and `fb${facebookAppId}://open`. A filter matches
      the cross product of its schemes and hosts, so merging registers `fb…://arul.hsrutility.com`
      and puts a custom scheme under `autoVerify`.
- [ ] The top-level `redirect` must return null for every scheme-less location — it runs on EVERY
      navigation — and `/` for every foreign-scheme URI, parseable or not: an ad link with a typo lands
      on the app, never on go_router's error page. It parks the target BEFORE the location becomes
      `/`, because the feed can only be reached through the splash's auth decision.
- [ ] ONE level of encoding on `referrer`. Double-encoding hands the app a single key literally named
      `ref=CODE&w=<uuid>`, and both attribution and the deferred deep link stop working. The six
      language codes are duplicated in the Worker (`LANG_RE`) by necessity — a seventh is two edits.
- [ ] The deferred target AND language are seeded from BOTH `captureOnce` / the bridge and the persisted
      prefs (main.dart), because either can win the startup race against the first catalog drain.
      Whoever consumes clears the pref (`clearPendingTarget` / `clearPendingLang`) — consuming one
      without the other re-opens the target next launch.
- [ ] Typed takes: the feed builds BEFORE the shell has switched tabs, so `consumeWallpaper()` must
      never eat a pending ringtone and `consumeRingtone()` never a wallpaper. Both screens re-check on
      every build AND listen to `ArulDeepLink.changes` — GA4F/Meta deliver mid-startup, a warm App
      Link arrives while the other tab is up, and an offstage screen gets no build otherwise.
- [ ] The ringtone scroll is arithmetic (`index × (RingtoneRow.extent + gap)`, zero top padding); a row
      that could grow taller than `extent` puts the wrong ringtone at the top.
- [ ] The Meta App ID's scheme is the SDK's convention — `fb<id>` — so a key-less dev build registers a
      bare `fb` scheme, which nothing sends; that is fine, not a bug.

An ad tapped inside Facebook/Instagram may load the https URL in their in-app webview rather than
handing the OS an intent, in which case an installed user still lands on Play. The fix is not in this
repo — put the URL (or the scheme form) in the ad platform's deep-link field so the platform does the
hand-off.

## Proving it on a device (installed half; deferred halves in deferred-links.md)

```bash
adb shell "am start -a android.intent.action.VIEW -d 'https://arul.hsrutility.com/r/<uuid>?lang=ta'"
adb shell "am start -a android.intent.action.VIEW -d 'fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi'"
node tools/drive.mjs dump   # debug build: expect the Ringtones dock cell active / Hindi labels
```
The inner quotes are load-bearing: an unquoted `&` is a background operator to the PHONE's shell, so
the app receives the URL cut at `&` — the target opens and `lang` silently never arrives (paid for on
the A001, 2026-08-26). A debug-signed build cannot verify the host (assetlinks lists release certs
only); force it for the test with `adb shell pm set-app-links --package com.hsrutility.arul 2 arul.hsrutility.com`.
