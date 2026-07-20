# Port Map — reference (c:\Anish\Pakiza) → Arul

For LOGIC, port = **copy + rename**, never re-implement. Presentation is the exception: Arul's
UI/UX is its own — port providers/domain/data/native verbatim, design screens fresh per
docs/ui-direction.md (the contracts in docs/edge-cases.md bind regardless of design).
Reference is READ-ONLY. One phase = one commit, human approves first. File:line pointers verified 2026-07-14 — grep if drifted.

## Rename table (apply on BOTH Dart and Kotlin/TS sides)
| Reference | Arul |
| --- | --- |
| `com.hsrapps.pakiza` — applicationId, namespace, Kotlin package dirs, ALL platform-channel strings (`FeedVideoPlugin.kt:55-56`, `WallpaperApplyChannel.kt:50` + their Dart mirrors) | `com.hsrapps.arul` |
| `pakiza://` deep-link scheme (AndroidManifest ~:61) | `arul://` |
| Storage keys `pakiza_access_token/_refresh_token/_profile/_locale/_theme_mode` | `arul_*` (fresh install, no migration) |
| Cache dirs/prefs `pakizaLiveWallpapers`, `pakiza_wallpaper_cache`, `pakiza_live_video`, `pakiza_live_active`, `pakiza_wallpaper_prefs` | `arul*` equivalents |
| Classes `PakizaApp/PakizaTheme/…/PakizaVideoWallpaperService` | `Arul*`; manifest service `.wallpaper.ArulVideoWallpaperService` |
| PhonePe order-id prefix `PKZ_` (`workers/src/lib/phonepe.ts:766,778`) | `DKS_` |
| CMS session cookie `pakiza_admin` (`workers/src/admin/auth.ts:22`) | `arul_admin` |
| Share filename `pakiza-$slug` (`wallpaper_share_provider.dart:175`) | `arul-$slug` |

## Copy VERBATIM, rename only — this code encodes on-device fixes
`workers/src/**` + `tsconfig.json` + vitest tests (then apply the strip + brand deltas below) ·
`android/…/kotlin/**` (`feedvideo/` + `wallpaper/`; `MainActivity.kt` WITHOUT its ringtone_set channel block) ·
`third_party/phonepe_payment_sdk/` · `lib/core/**` · `lib/data/**` · `lib/features/**` logic layers
(providers/domain/data — presentation/ is designed fresh) · `analysis_options.yaml` · `docs/analytics-events.md` ·
AndroidManifest blocks (**`configChanges` incl `uiMode|colorMode`**, FileProvider `${applicationId}`,
network-security-config, allowBackup=false + data-extraction rules) · gradle signing + `dartDefines()`/`manifestPlaceholders` helpers.

## Ringtones strip — **REVERSED 2026-07-17** (historical record kept below)
The strip below was applied during the original port, then reversed on 2026-07-17: Arul now HAS
ringtones. What was added back (Worker side; contract in the reversal task):
- `ringtones` table: id, title, category (not null), tags text[], audio_key, cover_key (nullable),
  mime, duration_ms, bytes, is_published, sort_order, created_at (db/ migration — separate task).
- `cron/build-catalog.ts`: allScopes = `["wallpapers", "ringtones"]`; ringtones branch orders
  `sort_order ASC, created_at DESC NULLS LAST`, drops rows missing audio_key, strips duration_ms +
  bytes (keeps audio_key, cover_key, mime), writes `catalog/ringtones/all_{page}.json`; a zero-row
  scope writes a valid empty all_1.json.
- `cron/sweep-canonical.ts`: CANONICAL_PREFIXES = `["wallpapers/", "ringtones/"]`; referenced keys =
  wallpapers.full_key ∪ ringtones.audio_key ∪ ringtones.cover_key (all rows).
- `routes/media.ts`: KIND_TABLE gains `ringtone → ringtones.audio_key`; confirm-upload stays
  wallpaper-only (product decision — no user ringtone submissions).
- R2 keys: audio `ringtones/<category>/<uuid>.mp3`, covers `ringtones/covers/<category>/<uuid>.jpg`
  (recipes in docs/media-conventions.md). Legacy per-app `src/admin/` has since been REMOVED
  (2026-07-20) — all authoring lives in the separate hsr-cms worker. Flutter side ported separately.

### Original strip (historical — no longer in force)
Worker — do these WITH the copy, or build-catalog crashes on the missing table:
`cron/build-catalog.ts:70` allScopes = `["wallpapers"]` + delete the ringtones SQL branch (:281-288) ·
`cron/sweep-canonical.ts:26` CANONICAL_PREFIXES = `["wallpapers/"]` · `routes/media.ts:29-32` KIND_TABLE
wallpaper-only + `:190` confirm-upload kind ∈ {wallpaper} · admin/: delete `ringtones.tsx` + its mount,
`ui.tsx:359` NAV_GROUPS entry, `app.tsx:105-113` dashboard count, `media.ts:26-38` ringtone prefix branch,
`submissions.tsx` ringtone-promote branch.
Flutter — do NOT port: `lib/features/ringtones/`, `just_audio`, ringtone ARB keys, the Ringtones tab/route,
MainActivity's ringtone channel, or the `WRITE_SETTINGS` permission.

## Category browse (Arul delta — the reference has NO equivalent; do not skip)
Browse axis = **category**, never static/live. `wallpapers.category` is a real column (db/schema/02).
- Worker: add `category` to build-catalog's wallpapers SELECT + emitted JSON (`cron/build-catalog.ts:271,336`)
  — still ONE `all_{page}` page set, no per-category files. CMS wallpaper form gets a category field
  (`admin/wallpapers.tsx` INSERT/UPDATE); `admin/media.ts:26-38` `prefixFor()` → `wallpapers/<category>/`
  (NOT the reference's posters/full split); `admin/submissions.tsx` approve → copy to the submission's
  category prefix and carry `category` onto the wallpapers row.
- Flutter: `WallpaperModel` gains `category` (freezed regen) · REPLACE `wallpaper_feed_filter.dart`
  (`{all, newest}`) with a category filter + chip row (All + 6 categories, client-side) · upload form
  requires a category select · analytics: feed/filter events carry the category.
- Categories are free text (no check constraint, no categories table): a 7th is an insert, not a migration.

## Brand deltas — Worker (~15 sites, all cosmetic)
`admin/ui.tsx:40,533,542,548,719,725` (CMS titles/brand/accent) · `admin/auth.ts:22` (cookie) ·
`routes/payments.ts:649-651` (callback HTML) · `admin/config.tsx:104` (placeholder email) · `lib/phonepe.ts:766,778`.

## Brand deltas — Flutter
`app.dart:105` title · `install_referrer_service.dart:7` kPlayPackageId · `settings_screen.dart:680,710`
(support email fallback + mail subject `Arul - Support Request`) · `manage_subscription_screen.dart:188` ·
`wallpaper_share_provider.dart:120` share copy · `upload_screen.dart:546` — read remote `policy_urls` instead of hardcoding.
**DELETE (Islam-only, do not port):** `lib/features/notifications/` + `hijri` dep + `notif*` ARB keys ·
`islamic_background.dart` · assets `islam_*`, `benefit_bg_islam.png`. Splash/sign-in/premium screens are
rebuilt fresh anyway (ui-direction) — port their providers, not their look.
**L10n:** copy 6 ARBs (`en,ta,te,kn,ml,hi`), drop the other 5; drop `notif*` + ringtone keys; re-key brand keys
(`appName`, `wallpapersTitle`, `settingsPremiumTitle`, `referShareMessage`); move the reference's ~19
hardcoded-English literals into ARB while porting.

## Phases (run `.claude/skills/phase-completion` at the end of each)
> **STATUS 2026-07-14 — Phases 1 and 5 are DONE and verified on-device (Nothing Phone 1).**
> The app builds, runs, and renders the real catalog from R2. Next up is **Phase 0**.
> Phase 4 is now a port of the LOGIC layers into an existing, working UI — not a rebuild.

0. **Provision** — every box in docs/provisioning.md; `workers/wrangler.toml` has no `TODO_` left.
1. ~~**Skeleton**~~ **DONE** — android/ generated + configured (edge-to-edge, predictive back,
   adaptive+monochrome icon, splash, R8, signing), `third_party/phonepe_payment_sdk` copied.
   Firebase/PhonePe/PostHog deps are COMMENTED in pubspec until their config exists — uncomment
   with the port, and add the google-services + crashlytics gradle plugins then.
2. **Backend** — apply `db/schema/01→03` + `db/seed.sql` to the NEW Neon DB. Copy `workers/src` + tests,
   apply the RINGTONES STRIP + brand deltas, set secrets, deploy (deploy-worker skill), verify JSON-404 live.
3. **Content import** — driven by the bucket's `catalog/catalog.json` manifest (verified 2026-07-14:
   428 assets = 211 static + 217 live, 6 categories, all qcStatus=pass; sampled files conform — videos
   1024×1824 h264 no-audio faststart, images 1080×1920 → NO re-encode expected; spot-check a few more).
   Map manifest → `wallpapers` row: mediaKey→full_key (keys stay as-is) · mediaType image/video→type
   static/live · **category→category** · subjectName/categoryName→title · delivered.width/height→width/height ·
   sizeBytes→bytes · scores.rank→sort_order. durationS is unreliable (mostly 0) — ffprobe or leave null.
   ONE transaction: insert all + `content_version` bump; build-catalog; verify DB = catalog = R2 counts
   and all 6 categories present. ⚠ Objects without a DB row are DELETED by the hourly sweep after the
   first successful rebuild (the manifest survives — sweeps cover `wallpapers/` and `catalog/<scope>/`).
4. **Flutter logic port** — the UI already exists; port the LAYERS BENEATH it. Order: api_client +
   AuthService → catalog repo (repoint `catalogProvider` at the Worker catalog + paging) → native
   Media3 pool (override `liveMediaBuilderProvider` — the seam is already there) → apply/share →
   premium/PhonePe (replace `entitlementProvider`'s stub with the live /me read) → referral → upload.
   Copy the reference's tests alongside each ported layer. Screens should barely change.
5. ~~**Arul UI**~~ **DONE** — design system (tokens/scrims/motion/type), component library, feed +
   splash/sign-in/premium/settings/upload, 6-locale l10n. Kolam+gopuram painter replaces the
   reference's Islamic painter. Still owed: real launcher-icon artwork (a vector mark ships now).
6. **Verify + release** — every line of docs/edge-cases.md true on-device (budget SoC if available);
   then release-build skill. Pre-launch owed: privacy policy live, PhonePe webhook registered, FLAG_SECURE added.

**Notifications feature:** NOT ported (Islamic: Hijri/Jummah). If wanted later — same local-notification
mechanics, South Indian festival dates served via `app_config` so no yearly app update. Fresh build decision.
