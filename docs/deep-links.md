# Deep links

Read this when touching the URL a share or an ad carries, the App Links / Meta-scheme setup, or
anything that turns an incoming link into a wallpaper, a ringtone or a language on screen. Share
payload and caption: [share.md](share.md). The three deferred (post-install) deliveries and their
test recipes: [deferred-links.md](deferred-links.md). The feed order it lands on:
[browse.md](browse.md).

## The two shapes the ad team pastes (nothing else is supported)

| Platform | Wallpaper | Ringtone | Language only |
| --- | --- | --- | --- |
| Google Ads App URL · WhatsApp share · any browser | `https://arul.hsrutility.com/w/<uuid>?lang=hi` | `https://arul.hsrutility.com/r/<uuid>?lang=ta` | `https://arul.hsrutility.com/w/?lang=hi` |
| Meta deep-link field (Facebook / Instagram) | `fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi` | `fb<META_APP_ID>://open?screen=ringtones&ringtone_id=<uuid>&lang=hi` | `fb<META_APP_ID>://open?lang=hi` |

`lang` ∈ `en ta te kn ml hi` (region tags and case tolerated, anything else dropped); `?ref=<code>`
rides the https form for referral credit; **`ilang=` is SHARE-only and an ad must never carry it**
([share.md](share.md)). The id-less form sets language and nothing else — keep the TRAILING SLASH
(`/w/`), matching the manifest's pathPrefix, or an installed phone opens a browser while an
uninstalled one reaches Play. Build https links with `InstallReferrerService.buildWallpaperLink` /
`buildRingtoneLink`, never by hand; the Meta scheme reuses the `META_APP_ID` the SDK meta-data is
baked from, so it cannot drift. Meta accepts the https form too — its scheme form needs App Dashboard
→ Settings → Android: package `com.hsrutility.arul`, class `…arul.MainActivity`. `screen=` alone
opens the tab; an id implies its tab; the parser reads the keys on both hosts.

## One URL, five deliveries, ONE parser, one slot

Every path ends in `ArulDeepLink` (`deep_link_target.dart`): a target (wallpaper · ringtone · tab)
plus a language, each consumed once by the surface that can act on it — the shell picks the dock
branch, the feed jumps to the wallpaper **on All**, the Ringtones tab scrolls the row to the **top of
All**, and `DeepLinkLocaleSync` (above `MaterialApp`) applies the language live.

| App state | Delivery | Where it enters |
| --- | --- | --- |
| Installed | https App Link (verified host) | go_router top-level `redirect` — Android hands Flutter the FULL intent URI |
| Installed | `fb<id>://open?…` from the FB/IG apps | same redirect; go_router normalises the empty path to `/` |
| Not installed, browser tap | Worker `/w/:id` · `/r/:id` → **200 bounce page, never a 302** ([deferred-links.md](deferred-links.md)) → Play `referrer=ref=…&w=<uuid>&lang=hi` (`r=` for ringtones) | `InstallReferrerService.captureOnce` |
| Not installed, Google App Campaign | GA4F deferred deep link | `MainActivity` → `DeferredLinkService` |
| Not installed, Meta ad | `AppLinkData.fetchDeferredAppLinkData` | same bridge, `source=meta` |

**The link's language ALWAYS wins** (owner's call) — over the device default and over a language the
user picked in Settings. It goes through `LocaleNotifier.setLocale`, so Settings shows it as the
current choice. The GA4-only event `deep_link_opened` (`kind`, `source`, id) fires on every landing;
it is deliberately NOT on the PostHog allow-list and not a Meta ★ event
([analytics-events.md](analytics-events.md)).

Traps, all of which fail SILENTLY — nothing logs. The first four drop the link into a browser; the
rest keep the app but lose the target:

- [ ] **The cert list must carry the cert Play actually signed this build with**, not only the upload
      key — Play re-signs every AAB, so an upload-key-only value verifies on a local release APK and
      fails on every real install. **Ground truth is the device** (`adb shell pm get-app-links
      <pkg>`), not the Console page, whose fingerprints were verified wrong on a real install. It
      takes a comma-separated list; list every candidate. **Note the value is a deployed SECRET, not
      a `wrangler.toml` var** — the toml line of that name is dead config
      ([known-issues.md](known-issues.md)).
- [ ] Four places must agree on the host: `kDeepLinkHost` (`deep_link_parser.dart`), the manifest's
      `android:host`, the `wrangler.toml` custom domain, and whoever serves
      `/.well-known/assetlinks.json`.
- [ ] `flutter_deeplinking_enabled` meta-data must stay true, or the intent opens the app onto `/`
      with the URI nowhere. The embedding passes `intent.data.toString()` — scheme, host, query
      intact — both cold and via `onNewIntent`.
- [ ] **Intent-filters are never merged across schemes.** A filter matches the cross product of its
      schemes and hosts, so merging would register `fb…://arul.hsrutility.com` and put a custom
      scheme under `autoVerify`. Today that means four filters: `arul://` (the PhonePe return), one
      autoVerify filter per App Link path (`/w/` and `/r/` were split apart), and
      `fb${facebookAppId}://open`.
- [ ] The top-level `redirect` must return null for every scheme-less location — it runs on EVERY
      navigation — and `/` for every foreign-scheme URI, parseable or not: an ad link with a typo
      lands on the app, never on go_router's error page. It parks the target BEFORE the location
      becomes `/`, because the feed can only be reached through the splash's auth decision.
- [ ] **ONE level of encoding on `referrer`.** Double-encoding hands the app a single key literally
      named `ref=CODE&w=<uuid>`, and attribution and the deferred deep link both stop working. The
      six language codes are duplicated in the Worker (`LANG_RE`) — a seventh is two edits, and so is
      the NORMALISATION around it: it lower-cases and strips the region tag exactly as `normalizeLang`
      does, or `hi-IN` is Hindi for an installed user and device-language for a fresh install.
- [ ] The deferred target AND language are seeded from BOTH `captureOnce`/the bridge and the
      persisted prefs — either can win the startup race against the first catalog drain. Whoever
      consumes clears the pref; consuming one without the other re-opens the target next launch.
- [ ] **Typed takes:** the feed builds BEFORE the shell has switched tabs, so `consumeWallpaper()`
      must never eat a pending ringtone and `consumeRingtone()` never a wallpaper. Both screens
      re-check on every build AND listen to `ArulDeepLink.changes` — GA4F/Meta deliver mid-startup, a
      warm App Link arrives while the other tab is up, and an offstage screen gets no build otherwise.
- [ ] The ringtone scroll is arithmetic (`index × (RingtoneRow.extent + gap)`, zero top padding); a
      row that could grow taller than `extent` puts the wrong ringtone at the top.
- [ ] The Meta App ID's scheme is the SDK's convention — `fb<id>` — so a key-less dev build registers
      a bare `fb` scheme, which nothing sends. That is fine, not a bug.

An ad tapped inside Facebook or Instagram may load the https URL in their in-app webview rather than
handing the OS an intent, in which case an installed user still lands on Play. The fix is not in this
repo — put the URL (or the scheme form) in the ad platform's deep-link field so the platform does the
hand-off.

## Proving it on a device (installed half; deferred halves in deferred-links.md)

```bash
adb shell "am start -a android.intent.action.VIEW -d 'https://arul.hsrutility.com/r/<uuid>?lang=ta'"
adb shell "am start -a android.intent.action.VIEW -d 'fb<META_APP_ID>://open?wallpaper_id=<uuid>&lang=hi'"
node tools/drive.mjs dump   # debug build: expect the Ringtones dock cell active / Hindi labels
```
**The inner quotes are load-bearing**: an unquoted `&` is a background operator to the PHONE's shell,
so the app gets the URL cut at `&` — the target opens and `lang` silently never arrives. A
debug-signed build cannot verify the host (assetlinks lists release certs only); force it with
`adb shell pm set-app-links --package com.hsrutility.arul 2 arul.hsrutility.com`.
