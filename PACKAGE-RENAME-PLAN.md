# Package Rename: `com.hsrapps.*` → `com.hsrutility.*` (Arul + Pakiza)

> Working plan, 2026-08-07. Covers BOTH repos (`c:\Anish\Arul`, `c:\Anish\Pakiza`). All file:line refs verified against both repos today.

## STATUS — 2026-08-07
**Arul repo: DONE** (uncommitted). Rename complete, 0 `com.hsrapps` left · 8 channels match Dart↔Kotlin · hook path moved · `analyze` clean, 218 tests pass, debug APK builds · 5 locales' `wallpaperShareCaption` filled.
**Arul consoles: PARTLY DONE.** Firebase = **NEW project `arul-prod-db4f8`** (see §2a — the earlier "reuse `arul-502411`" advice was overridden). Both SHA pairs registered, web client created, `google-services.json` in repo, `env/{dev,prod}.json` updated, worker secret `GOOGLE_WEB_CLIENT_ID` swapped + **deployed** (version `b80ff7ed-40d2-4193-a650-dc26ebdc7046`).
**Arul remaining:** new Play listing (§2c) · Google Ads relink (§2e) · Meta (§2d) · PhonePe POC (§2f) · on-device test (§4B).
**Pakiza: NOT STARTED** — parked by owner's call, handle later. Everything in §1c/§2 still applies to it.

⚠️ **The old `com.hsrapps.arul` build in Play review now fails sign-in** (the worker validates only the new `aud`). Withdraw that submission rather than letting a reviewer hit a broken app — a "doesn't function" finding is worse than a clean testing-requirement denial.

## 0. The one fact that shapes everything
- **A Play package name is permanent.** `com.hsrutility.arul` = a **brand-new Play app**, not an update. Old listings: unpublish, or self-service delete (unpublished, <100 installs, 7-day recovery).
- **Do NOT transfer the old apps to the business account.** Test tracks don't transfer, and a pre-production app has nothing else worth moving. **Create both new-package apps directly on the business (organization) account** — org accounts are **exempt from the 12-tester/14-day closed-testing rule** (personal accounts created after Nov 2023 are not).
- Business account needs a **D-U-N-S number** (free, up to 30 days) + identity verification — **start this first**, it's the long pole.
- New package = fresh install: all `SharedPreferences`/tokens/grants (incl. `WRITE_SETTINGS`) reset. Moot pre-launch; no code needed.

## 1. Repo changes — identical recipe, both apps

### 1a. The safe find/replace
The exact string `com.hsrapps.arul` (resp. `com.hsrapps.pakiza`) appears ONLY in package-name contexts — it never matches the legacy `hsrapps.com/...` privacy-policy **domain** URLs. So per repo:
1. **Replace exact string** `com.hsrapps.arul` → `com.hsrutility.arul` repo-wide (lib/, android/, test/, docs/, .claude/, CLAUDE.md). Same with `pakiza`.
2. **NEVER blanket-replace bare `hsrapps`** during the mechanical rename — the `hsrapps.com` domain notes in `db/seed.sql`, docs, comments, and worker tests need deliberate rewording, not substitution. *(Arul: DONE 2026-08-07 — every `hsrapps.com` reference removed: seed + prod `policy_urls` now `hsrutility.com/privacy/` + `/terms/` (catalog rebuilt, v60), comments reworded to keep their warnings, test fixtures swapped. Do the same in Pakiza.)*
3. **Move the Kotlin tree**: `android/app/src/main/kotlin/com/hsrapps/<app>/` → `.../com/hsrutility/<app>/` (`git mv`). The replace in step 1 already fixed every `package`/`import` statement inside.
4. `flutter clean` (build/ and .dart_tool/ hold stale artifacts under the old package).

### 1b. What the replace hits (verify each after) — Arul
- [gradle] `android/app/build.gradle.kts:37` `namespace`, `:57` `applicationId` — keep the two EQUAL.
- [kotlin, 12 files] `MainActivity.kt` (pkg + 5 imports + 2 channel consts), `feedvideo/FeedVideoPlugin.kt` (:55-56), `feedvideo/VideoThumbnailChannel.kt` (:40), `share/DirectShareChannel.kt` (:44), `share/ShareWatermarkChannel.kt` (:72), `wallpaper/` ×7 (pkg stmts, `BuildConfig` imports, `WallpaperApplyChannel.kt:44`).
- [dart channels — must stay byte-equal to Kotlin, 8 channels] `lib/core/config/build_info.dart:7` · `wallpaper_apply_service.dart:85` · `video_thumbnail_service.dart:21` · `share_watermark_service.dart:78` · `feed_video_player.dart:133-134` · `direct_share_service.dart:18` · `ringtone_set_service.dart:95`.
- [dart, functional] `lib/features/referral/data/install_referrer_service.dart:7` `kPlayPackageId` — feeds the Play URL in share + referral attribution.
- [tests] `test/features/wallpapers/wallpaper_share_test.dart:313` · `test/features/referral/install_referrer_test.dart:54`.
- [hook — FAILS CLOSED] `.claude/hooks/release-flag-secure-guard.js:20` hardcodes the `com/hsrapps/arul/MainActivity.kt` path; if stale it **denies every `.aab` build**. Must land in the same commit as the dir move.
- [docs] `CLAUDE.md:8,13` · `docs/analytics-ops.md:9` (GA4 setprop) · `.claude/skills/on-device/SKILL.md:34` · `.claude/skills/release-build/SKILL.md` (:68-71 SHA note, :71 "already uploaded" is now the OLD listing).

### 1c. Same list — Pakiza deltas
- `android/app/build.gradle.kts:30` namespace, `:57` applicationId.
- Kotlin tree: 11 files (MainActivity + 3 imports, `feedvideo/`, `share/ShareWatermarkChannel.kt`, `wallpaper/` ×8). **7 channels** (no `build_info`/`video_thumb`/`direct_share`; has `device_info`): `MainActivity.kt:33-34`, `FeedVideoPlugin.kt:55-56`, `ShareWatermarkChannel.kt:73`, `WallpaperApplyChannel.kt:44` ↔ Dart `device_capabilities.dart:19`, `ringtone_set_service.dart:98`, `wallpaper_apply_service.dart:77`, `share_watermark_service.dart:75`, `feed_video_player.dart:133-134`.
- `lib/features/referral/data/install_referrer_service.dart:7` `kPlayPackageId` (+ Play URL at `wallpaper_share_provider.dart:269`).
- Tests ×3: `install_referrer_test.dart:51`, `wallpaper_share_test.dart:322,361`.
- Hook: `.claude/hooks/release-flag-secure-guard.js:17-21`.
- Docs: `docs/analytics-events.md:55` setprop · `.claude/skills/on-device/SKILL.md:32` · `pubspec.yaml:107-108` comments · CLAUDE.md identifier lines.

### 1d. Explicitly NOT changed (verified decoupled)
- `pubspec.yaml` `name:` (Dart package `arul`/`pakiza` — all imports depend on it).
- Deep-link schemes `arul://` / `pakiza://` (manifest `<data android:scheme>`; Pakiza's `_appSchema` at `premium_purchase_provider.dart:100`) — schemes are package-independent.
- Storage keys `arul_*`/`pakiza_*`, notification channel ids, cache-file prefixes, `DKS_`/`PKZ_` order prefixes.
- FileProvider authority — already `${applicationId}.fileprovider` in both manifests; Kotlin builds it from runtime `packageName`. Auto-follows.
- Manifest `.MainActivity` / `.wallpaper.*Service` — relative names resolve off `namespace`. Auto-follows.
- **workers/ — no CODE changes.** No package name anywhere in `workers/`; PhonePe payloads, JWT, share/referral server side carry none. *(But a NEW Firebase project does force one SECRET change + deploy — see §2a. Arul: done. Pakiza: only if it also moves projects.)*
- Upload keystores (`arul-upload.jks` / `pakiza-upload.jks`), `key.properties`, `CN=HSR Apps` — signing identity is independent of applicationId; reuse as-is.
- Vendored `third_party/phonepe_payment_sdk` (Pakiza) — its `packageName` refs are other UPI apps.

## 2. External consoles — per app, in this order

### 2a. Firebase — Arul moved to a NEW project (`arul-prod-db4f8`)
> **Two valid shapes; Arul took the second.** (i) Add the new package as a second Android app inside the EXISTING project — web client id unchanged, worker untouched, GA4 property + Ads link carry over, least work. (ii) A brand-new project — clean one-app-per-project, but it is a new Google Cloud project, therefore a **new web client id**, therefore `env/*.json` + a worker secret + redeploy + a full Google Ads re-link. **Arul chose (ii) on 2026-08-07** and paid all of that. Pakiza: pick deliberately, and keep both repos consistent.
>
> **Hard constraint either way:** the Android OAuth client and the web client used as `serverClientId` **must live in the same project**, or the idToken `aud` check fails. No mixing.

Firebase apps can't be renamed → **Add app → Android → new package**:
1. Register `com.hsrutility.<app>` → download new `google-services.json` → replace `android/app/google-services.json` (git-ignored). The google-services Gradle plugin **hard-fails on package mismatch** — the old file blocks all builds after the gradle edit (useful tripwire).
2. Add SHA-1 **and** SHA-256 of: debug keystore + upload keystore now; **App signing key later** (Play → App integrity, exists only after first upload). Re-download the json after adding SHAs — before that, `oauth_client` is `[]` and the file is incomplete.
3. On a NEW project you must also **Authentication → Sign-in method → Google → Enable** — that is what creates the web client. Firebase auto-provisions the Android OAuth clients when you add SHAs, so never hand-create them in Cloud Console too: a (package, SHA-1) pair is globally unique and the duplicate fails to save.
4. Old project/app entry: keep it for history. **Never delete the old GA4 stream** (erases its data). Note a new project = a new **GA4 property**, not just a new stream — audiences/key-events do NOT carry over.

**Arul's live values** (project `arul-prod-db4f8`, number `1083884444243`): web `…c5i3soqml5hiohaeodhrd8hl5fkgkldd` · Android-debug `…8i0o92tr5uf0ie5ajgkvfn2gh5kpo9pe` (cert `c8303e87…`) · Android-upload `…pes9bb4moi0l2vagqi1k8530lj0mjjtm` (cert `9df7525f…`).

**Fingerprints** (same values regardless of package — they belong to the keystore, not the app id; but each must be re-registered because the OAuth client binds the *pair*):
| Keystore | SHA-1 | SHA-256 |
| --- | --- | --- |
| Arul upload | `9D:F7:52:5F:3C:8B:62:EF:E5:DD:92:51:84:8B:10:77:EC:EA:90:3D` | `0E:29:23:B9:57:58:66:DD:92:9B:37:5F:89:E7:9C:4C:E7:94:85:CC:99:E7:86:E5:BA:0F:A1:FC:A9:C1:35:D9` |
| Pakiza upload | `C0:7C:6E:D3:4D:EB:3F:23:E8:3B:81:8A:4E:E2:F9:80:B7:0A:5F:1F` | `B0:95:0F:F4:90:A3:21:0C:DF:FD:E5:47:DA:DB:6A:95:3A:31:DF:93:4F:B0:C2:22:58:15:3A:4D:FE:4E:76:2D` |
| debug (shared, per-machine) | `C8:30:3E:87:30:E4:0E:4D:48:94:1C:90:A9:DD:0A:D8:A1:D4:55:5B` | `3E:9C:93:97:F0:FA:92:7C:30:CE:5C:5B:8F:28:BC:A7:10:A4:85:12:00:CD:11:AA:66:EF:4C:C5:2F:E7:02:02` |

### 2b. Google Sign-In + the worker
- Adding SHAs in Firebase auto-provisions the **Android OAuth client** (bound to package+SHA-1) → new `GOOGLE_ANDROID_CLIENT_ID` in `env/dev.json` (debug client) + `env/prod.json` (upload client). Pakiza also has `env/sbx.json`.
- `GOOGLE_WEB_CLIENT_ID` changes **only if the project changed**. It did for Arul → `env/*.json` + worker secret + deploy. [google.ts:51](workers/src/lib/google.ts#L51) passes ONE `audience` string, so the swap is a hard cutover: the old package's build stops authenticating the moment you deploy. (`jose` accepts an array if you ever need both to overlap.)
- Secret goes in via `npx wrangler secret bulk <file.json>` — never a shell pipe (CLAUDE.md §9).

### 2c. Play Console (business account) — a NEW listing, so EVERYTHING is re-entered
Nothing carries over from the old app. Budget real time here; this is the largest remaining chunk.
- Create app under the new package. Ship `.aab`; accept the 2026 default Google-generated ("quantum-ready hybrid") signing key; **reuse the existing upload keystore** (allowed — the upload key is only an upload identity). versionCode just has to increase within the new app.
- **Store listing from scratch:** app name, short + full description, app icon, feature graphic, phone/tablet screenshots, category, tags, contact email (`support@hsrutility.com`), external marketing opt-out.
- **Policy declarations from scratch — this is where the last rejection lived:**
  - **Data safety form** — every collected type, purpose, sharing, retention/deletion. Must match what the app + Workers actually do (Google account identity, email; payment via PhonePe; analytics) and must agree with the privacy policy.
  - **Content rating** questionnaire (re-answer; rating does not transfer)
  - **Target audience & content**, **Ads declaration** (no ads), **Government apps**, **Financial features** (declare the UPI subscription), **Health**, **Data deletion URL** → `hsrutility.com/delete-account/`
  - Privacy policy → `hsrutility.com/privacy/`; keep the Play copy in step with the in-app/site copy (CLAUDE.md §1)
  - **App access** — sign-in is mandatory in this app, so reviewers MUST get working credentials or a documented Google-sign-in path, or it gets rejected as unreviewable. Fill this in properly.
- **Org account = exempt from the 12-tester/14-day closed-testing gate.** Verify the account really is an *organization* type (D-U-N-S verified) — if it is actually another personal account, the exemption does not apply and the gate returns.
- After first upload: copy the App signing fingerprints → Firebase (2a-2), re-download `google-services.json`. **Expect THREE keys, not one** — new apps auto-enrol in quantum-ready hybrid signing, so Play publishes a classical + PQC pair for newer devices plus a classical key for Android 16-, and *"you must copy the fingerprints for three keys and register each of them with your API providers."* Current nav: **Protected with Play → Play Store distribution → Go to Play app signing → App signing key** (the older "Release → Setup → App integrity" label is stale).
- Optional: re-link Firebase ↔ Play Console (Android vitals / install data) for the new app + project pair.
- Old-package apps: **withdraw the in-review submission first** (its sign-in is dead post-cutover), then unpublish → self-service delete when eligible.

### 2d. Meta — only TWO fields, and it must wait for Play
**Path:** developers.facebook.com/apps → app → **App settings → Basic** → **Android** pane. *(Meta's own docs no longer spell this nav out — verify by eye; they reorganize the dashboard without updating docs.)*
- **Change exactly two fields:** **Google Play Package Name** → `com.hsrutility.<app>`, and **Class Name** → `com.hsrutility.<app>.MainActivity`.
- **Key hashes are NOT needed.** They authenticate the app↔Facebook-app handshake used by **Facebook Login** — this app is **events-only** (`facebook_app_events`; no `FacebookActivity`/`CustomTabActivity` in the manifest), and app events authenticate via App ID + Client Token. This deletes the whole `keytool | openssl sha1 | openssl base64` step **and** removes the Play-App-Signing-SHA dependency from the Meta step.
- ⏳ **Play resolution.** Meta validates the package against Google Play. Two distinct failure modes: (a) saving the name at all → *"There was a problem verifying this package name"*; (b) going Live → *"URL(s) listed on your app dashboard settings could not be accessed for platform compliance review… Android: Google Package Name"*, with reports of Meta **auto-reverting the app to Development mode**. **Internal testing is documented as insufficient — use an OPEN testing track** so the store URL resolves publicly. No "use this package name anyway" override is documented for 2026; don't plan around one. *(Arul 2026-08-07: the save went through pre-publication — so (a) didn't bite. Still re-check Live mode after the listing exists.)*
- **Two packages at once: unverified.** Meta documents a singular package field and says nothing about multiples. Don't plan around it — flip it once at cutover (the old app is abandoned, not run in parallel).
- **Unchanged:** `META_APP_ID`, `META_CLIENT_TOKEN`, and the manifest — `com.facebook.sdk.ApplicationId`/`ClientToken` are App-ID-scoped, not package-scoped. Event history binds to the App ID and persists. Install attribution restarts at zero regardless (new package = new app to Play).
- **Edit the existing Meta app in place — do NOT create a new one.** Everything downstream keys off the **App ID**: the Events Manager dataset ("your app ID will remain the same and will be linked to your dataset ID"), the ad-account link, custom audiences. A new Meta app would force a new dataset (one app per dataset) and a fresh ad-account link. Events Manager needs **nothing** done.
- Verify after the swap with **App Ads Helper** (input is the App ID, not the package — look for the full green circle, then check *Meta app setup → Android*).
- **If you run Meta app-promotion ads:** update `object_store_url` / `APP_STORE_URL` on every live ad set and creative — that field still points at the dead Play listing. Also expect the **install metric to restart at zero** (new package = new app), and with no installs in the last 28 days, install campaigns fall back to optimizing for link clicks until installs accumulate.
- Minor: re-copy the **Install Referrer Decryption Key** from the Android card and confirm it still matches whatever consumes it — undocumented whether it rotates on a package change. *(Arul reads the Play referrer for its own `ref=` code via `play_install_referrer`, so this likely doesn't apply.)*
- **Nothing to do:** SKAdNetwork and Aggregated Event Measurement are iOS-only, and Google **retired the Android Privacy Sandbox / Attribution Reporting API on 2025-10-17**.

### 2e. Google Ads (shared account 750-756-8746) — relink + re-import
> **"Linked accounts" no longer exists — it is Tools → Data manager in 2026.** Any doc saying `Admin → Linked accounts` is stale. Also: the Firebase console **cannot** create the Ads link ("Google Ads linking is set up and managed within Google Analytics"), and **"Firebase" is no longer a conversion-import source** — imports run through the GA4 property.

**Prerequisites:** ONE Google account holding Ads **admin** + Firebase **Owner** on `arul-prod-db4f8` + GA4 **Editor**. **Auto-tagging ON.**

1. Confirm the new GA4 property has an app data stream for `com.hsrutility.arul`.
2. **Fire a real `purchase`** from the new build. Nothing below works until the event exists.
3. GA4 → **Admin → Data display → Events → Key events** → mark `purchase` as a key event. **Hard gate:** *"Only events marked as key events in Google Analytics are eligible for import."* (`purchase` is NOT auto-collected — `first_open`/`in_app_purchase` are; yours is manual.)
4. Ads → **Tools → Data manager → + Connect Product → Google Analytics (GA4) & Firebase** → select the property/project → Next → keep **Personalized Advertising ON** → **Link**.
5. **Wait 24–48h** — documented propagation after linking / marking a key event.
6. Ads → **Goals → Summary → + Create conversion action** *(older UI: "+ New conversion action" — same button)* → **Conversions on an app** → **Set up** → source **Google Analytics** *(the three options are Google Analytics / Google Play / Third party app analytics)* → select `purchase` → **Done**.
7. Ads → **Goals → Conversions → Summary → Goals tab → Edit goal** → **Conversion action optimization** → set the new action **Primary**; also expand **Account default** → **Make this an account-default goal**. **Both are required** — primary alone isn't enough for default bidding.
8. Set the OLD action to **Secondary (observe only)** — do NOT remove it the same day. Deleting loses history; going Secondary keeps reporting while stopping it from steering bids. **This window is the highest-cost failure mode: campaigns bidding toward a dead action starve Smart Bidding.**
9. **Audit campaigns on campaign-specific goals** (Campaigns → Settings → Goals) — *"changes made to your account-level goals won't be applied to campaigns that aren't strictly using account-level goals."* Those must be repointed by hand. Bulk path: Goals → Campaigns → select → Edit → **Update conversion goals**.
10. **Unlink `arul-502411` in Data manager BEFORE deleting the old Firebase project** — Google documents the unlink behaviour (history retained, no new data) but says nothing about outright deletion.
11. Ease Smart Bidding targets (tCPA/tROAS) gradually after the switch.

**Play ↔ Ads link (A7) — separate, and OPTIONAL here.** It is scoped to the *developer account*, so the move to the org account means redoing it: Ads → **Tools → Data manager → Featured products → Google Play → Link** (enter the Play owner's email) then Play Console → **Settings → Linked services → Link Google Ads Account** (customer ID `750-756-8746`). **Blocker:** Play accounts with **more than one owner cannot link**. Skip it unless you want Play-billing conversions or app remarketing lists — your `purchase` already arrives via GA4, and doubling both up risks double-counting (you bill through PhonePe, not Play Billing, so there is little to gain).

### 2f. PhonePe — MANDATORY external step
- The package name IS registered with PhonePe at onboarding (not self-service in the dashboard), and their fraud layer **blocks live transactions from an unregistered package** — FRA "Internal Security Block". Their FAQ: *"If your URL/package name changed after you onboarded, reach out to your business point of contact and get it updated."*
- **Get the new package registered via the business POC / merchant-integration@phonepe.com, with written confirmation, BEFORE release.** SDK init itself (merchantId + flowId + env) carries no package — the check is server-side against the APK identity.
- Server v2 APIs (OAuth, order create, subscription setup) carry no merchant package name (`targetApp` = the UPI app, e.g. `com.phonepe.app`) → **Workers unaffected.** Then verify: one sandbox mandate setup + debit under the new package (`/verify-payments`), and one small production transaction before full rollout.

### 2g. No action: PostHog (API key only) · CDN/R2 · Neon · hsr-cms.

## 3. Order of operations
1. ~~D-U-N-S + business Play account~~ — confirm the account type is **organization**, not a second personal one.
2. ~~Firebase: register app, debug+upload SHAs, download json~~ *(Arul ✓)*
3. ~~New client ids → `env/*.json`~~ *(Arul ✓)* + ~~worker secret + deploy~~ *(Arul ✓, only needed because the project changed)*
4. ~~Repo edits §1 + swap `google-services.json`~~ *(Arul ✓)*
5. **Withdraw the old in-review submission** (sign-in is dead on it post-cutover).
6. On-device verification §4B — the one thing local checks cannot prove.
7. Play: create the new app, complete the whole listing + policy set (§2c), upload first `.aab` to internal testing.
8. Post-upload: App-signing SHAs → Firebase + Meta; re-download json; Ads relink + conversion import (§2e); **PhonePe package re-registration confirmed in writing** (§2f).
9. Install from the Play track → §4C. Then unpublish/delete the old listing.
10. Pakiza: repeat §1c + §2 end to end.

## 4. Testing guide — proves nothing broke

### A. Build-time tripwires (fail loud if missed)
- `flutter clean && flutter pub get && dart run build_runner build -d && flutter gen-l10n && flutter analyze` — clean.
- `flutter test` — the package-id literal tests (§1b/1c) now assert `com.hsrutility.*` and pass.
- Debug build compiles ⇒ google-services.json matches; no `ClassNotFoundException: ...MainActivity` on launch ⇒ namespace/Kotlin move consistent.
- `cd workers && npx tsc --noEmit && npx vitest run` — green with zero worker CODE edits (proves backend decoupling). *(Arul ✓ tsc clean, 197 pass / 7 skipped.)*

### B. On-device, debug build (`--dart-define-from-file=env/dev.json`)
> 🚨 **UNINSTALL the old package from the test device FIRST.** The Meta SDK registers a content provider whose authority is `com.facebook.app.FacebookContentProvider<APP_ID>` — derived from the **Facebook App ID, not the package**, and globally unique per device. With `com.hsrapps.arul` and `com.hsrutility.arul` both carrying the same `META_APP_ID`, the second install fails with `INSTALL_FAILED_CONFLICTING_PROVIDER`. Looks like a build problem; isn't.
- **Google Sign-In** completes AND the backend accepts it (proves new Android OAuth client + debug SHA + the new web-client `aud` agreeing with the deployed worker secret). A device-side success with a server-side 401 is the signature of an `aud` mismatch.
- **Every platform channel** — any `MissingPluginException` in logcat = Dart/Kotlin channel-string mismatch: video feed plays (feed_video + events) · wallpaper apply, incl. Android 12+ no-cold-restart · live wallpaper via OS chooser (wallpaper service resolves) · ringtone preview + set (fresh `WRITE_SETTINGS` grant flow appears — expected) · share (watermark channel; link contains `id=com.hsrutility.<app>`) · Arul: video_thumb, direct_share, build_info; Pakiza: device_info.
- **PhonePe sandbox** purchase: SDK launches, `arul://`/`pakiza://` return lands, webhook flips entitlement.
- **Analytics**: `adb shell setprop debug.firebase.analytics.app com.hsrutility.<app>` → events in GA4 DebugView **on the new project's GA4 property** (Arul: a whole new property, not a new stream); PostHog panel event; Meta test events under the updated package.
- **Crashlytics**: forced test crash appears on the NEW Firebase app entry.

### C. Release path
- `flutter build appbundle` succeeds ⇒ `release-flag-secure-guard` found MainActivity at the new path AND `FLAG_SECURE` is active; version-guard consumed the bump.
- `jarsigner -verify -verbose -certs` on the artifact → `CN=HSR Apps` (upload key reused correctly).
- Install from Play internal testing (now Play-signed): **repeat Sign-In** (proves App-signing SHA registered — the classic silent breaker), one gated action (apply/set), one sandbox payment, share link opens the NEW Play listing.
- Check FLAG_SECURE active on the Play-installed build (screenshot blocked) — `isPlayInstall()` gate.

### D. Cross-repo invariants
- `android/**/wallpaper/**` still byte-identical between repos modulo `arul`/`pakiza` identifiers (now under `com.hsrutility.*` in both).
- `git grep -n "com.hsrapps"` in BOTH repos returns **nothing**; `git grep -n "hsrapps"` also returns **nothing** once the §1a-2 domain cleanup is done (Arul ✓ 2026-08-07; Pakiza pending).
