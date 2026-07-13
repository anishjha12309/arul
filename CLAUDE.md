# CLAUDE.md — Arul

> Read first, every session. Build plan: [docs/port-map.md](docs/port-map.md) · Behavior checklist: [docs/edge-cases.md](docs/edge-cases.md) · Backend: [docs/architecture.md](docs/architecture.md) · Media: [docs/media-conventions.md](docs/media-conventions.md) · Data: [docs/data-model.md](docs/data-model.md) · Cloud setup: [docs/provisioning.md](docs/provisioning.md).

## 0. Reference Implementation — the prime directive
**`c:\Anish\Pakiza` (a shipped app with this exact architecture) is the READ-ONLY reference.** Build Arul by COPYING its code, then renaming per the port map — never re-implement from memory: that source encodes months of on-device fixes (decoder limits, PhonePe endpoint quirks, sweep safety). Never edit, commit, or deploy anything inside the reference folder. Backend, data flow and feature behavior must match the reference exactly; **the UI/UX is Arul's own** ([docs/ui-direction.md](docs/ui-direction.md)) — screens are designed fresh, but the behavioral contracts in docs/edge-cases.md bind regardless of design. When unsure about any behavior, read the reference source.

## 1. Project
**Arul** — Android-only (v1) South Indian wallpaper app. Flutter, Dart 3.12+. Pillars: **Wallpapers** (Shorts-style feed, static + live video) · **Settings** (incl. upload-your-content, wallpaper-only). **No ringtones feature** — the reference's ringtone code is NOT ported (strip list in docs/port-map.md; bucket + DB are wallpapers-only). Premium gated via PhonePe UPI Autopay. Package `com.hsrapps.arul`. Support `support@hsrutility.com`. Content: R2 bucket `south-indian-wallpapers` — 428 curated devotional wallpapers (211 static + 217 live) in 6 categories (Amman, Ayyappan, Murugan, Perumal, Sivan, Temples), media-rule-conforming, import via bucket manifest (port-map Phase 3). **Never share a bucket/KV/DB with another app — the hourly sweep would delete the other app's media.**

## 2. The One Architecture Rule
**Media-heavy, read-heavy. Cost = media egress.**
- **Media:** Cloudflare R2 (**zero egress**) + CDN — this is why it's affordable.
- **Browse feed:** edge-cached catalog JSON from the `build-catalog` Worker (CMS-triggered or hourly cron; the same cron sweeps orphaned R2 objects). **Never hits DB.**
- **DB (Neon Postgres via Hyperdrive):** per-user state only. Reached **only** from Workers — never the app.
- **Authoring:** CMS at `arul-api.hsrutility.com/admin` — row write + `content_version` bump + rebuild + purge, atomically. Near-instant updates via `catalog/version.json` + `?v=`.
- **No server-side transcoding.** ffmpeg locally per [docs/media-conventions.md](docs/media-conventions.md).

## 3. Stack (decided — do NOT re-litigate; versions pinned in pubspec.yaml / workers/package.json)
**Before implementing ANY package, fetch its pub.dev / vendor docs. Never code from memory.**
| Concern | Choice |
| --- | --- |
| State / Nav | Riverpod 3 (riverpod_generator) · go_router |
| Backend | Cloudflare Workers (Hono, TS) = API + CMS + crons · Neon via Hyperdrive · Workers KV · R2. Code in `workers/`. |
| Auth | Google one-tap (`google_sign_in` v7: instance → initialize → authenticate) → Worker verifies idToken (`aud` = WEB client id) → identity-only JWT (15m access + 60d rotating refresh) |
| Payments | PhonePe v2 Autopay (OAuth), server calls in Workers only. One trial per user (`trial_end` = consumed-marker); repeat = ₹199 TRANSACTION setup. Endpoint gotchas: [workers/README.md](workers/README.md) — re-verify there, never from memory. |
| Analytics | `AnalyticsService` → Composite = PostHog (all events) + GA4/`firebase_analytics` (all + ★→`login`/`purchase`) + Meta (★ only, gated on dart-defines). **Never call SDKs from widgets.** |
| Crash/Perf | Crashlytics + Performance behind `CrashReporter`/`PerformanceMonitor`; run in all real builds, only `flutter test` skips. Needs git-ignored `android/app/google-services.json`. |
| Video | Native Media3 ExoPlayer texture pool (`FeedVideoPlugin` platform channel) — players REUSED across clips (setMediaItem swap, never dispose+recreate). Live MP4 from CDN; shimmer until first frame; no posters. |

## 4. Layout
Feature-first; Riverpod providers are the only cross-layer glue. App reaches the backend only via `lib/core/api/api_client.dart`.
```
lib/  main.dart · app/ · core/{config,api,error,analytics} · features/{auth,wallpapers,premium,referral,upload,settings} · data/{models,repositories}
workers/  Worker API + CMS + crons (TS)   db/schema/  apply 01→03, then seed.sql   docs/  reference docs
```

## 5. Premium Entitlement — THE Cross-Cutting Rule
`isPremium` = (status ∈ {trialing, active, **cancelled**} AND `current_period_end > now`) OR `users.reward_premium_until > now`. `cancelled` keeps premium until period end; `paused`/`expired` get none. **Entitlement is NEVER in the JWT** — gated actions live-read Neon so purchase/expiry/refund apply instantly.
**Gated (ALL content is premium):** wallpaper apply + share. **Always free:** browse, preview. Media keys are public BY DESIGN (soft gate); the real gate is Worker `/media/signed-url` → live entitlement check → short-lived signed URL. Client gate `ensurePremium()` must **await** `entitlementProvider.future` (a loading snapshot must never bounce a premium user), track `${action}_blocked_premium`, route `/premium?source=`.

## 5b. Browse Model — category, never type
`wallpapers.category` (amman·ayyappan·murugan·perumal·sivan·temples) is THE browse axis: feed chips filter by category, static + live interleave inside each one. **Never filter/tab by static vs live** (`type` is a rendering hint) and never port the reference's All/New tabs. R2 keys are category-partitioned (`wallpapers/<category>/…`) — not the reference's posters/full split. Categories are free text: a new one is an insert, not a migration. Deltas: [docs/port-map.md](docs/port-map.md).

## 6. Localization
6 languages (ARB, `gen_l10n`): `en, ta, te, kn, ml, hi`. Only UI chrome localized; server content as-authored.

## 7. Theming
Light / Dark / System, persisted. Fixed brand seed — Kanjivaram maroon + temple gold ([docs/ui-direction.md](docs/ui-direction.md)). ALL colors via `lib/app/theme/design_tokens.dart` — no literal `Color(0x…)` in screens (the reference leaked 153 literals across 19 files; do not repeat that). **Never seed from device wallpaper / dynamic color.**

## 8. Known Gotchas (MUST hold — full checklist in docs/edge-cases.md)
1. Live video files: **1024×1824 only** (w%128==0, h%32==0, fits 1088×1920 hw-decoder cap) — anything else hits the green-edge / software-decode bug class on budget SoCs.
2. Android 12+ wallpaper-apply restart: manifest `configChanges` includes `uiMode|colorMode` + `onConfigurationChanged` + dark launch theme. Apply must never cold-restart the app.
3. Sign-in auto-launches FULL `authenticate()` on first frame — NEVER swap to lightweight/silent auth (retention decision).
4. PhonePe: notify user 24h before each debit (hourly cron); SDK order token + the working cancel path are in workers/README.md.
5. Hyperdrive query caching stays OFF (caused ~60s staleness).
6. Stale catalog ≠ cache bug: pages are dynamic — fix by rebuilding, never by purging.

## 9. Secrets & Environment
**Never hardcode keys.** App: `--dart-define-from-file=env/dev.json` (git-ignored; template `env.example.json`). Worker: `wrangler secret put <NAME>` (list in workers/README.md); local dev `workers/.dev.vars` (git-ignored, holds `DATABASE_URL` too). `.gitignore` covers `env/`, keystores, `key.properties`, `google-services.json`, `.dev.vars`. `TRIAL_TOMBSTONE_SECRET`: set once, **NEVER rotate** (rotation orphans tombstones and re-opens trial farming).

## 10. Commands
```bash
flutter pub get && dart run build_runner watch -d     # codegen
flutter gen-l10n && flutter analyze && flutter test
flutter run --dart-define-from-file=env/dev.json
cd workers && npm i && npx tsc --noEmit && npx vitest run
npx wrangler deploy                                   # deploy IS part of done for workers/
curl -X POST $API/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
```

## 11. Definition of Done & Git
Checklist: `.claude/skills/phase-completion/`. **Quick:** `flutter analyze` clean + formatted · worker `tsc`+tests green **+ deployed** · loading/empty/error states · localized edge cases · analytics fire · no secrets. **No tests for premium/payments/inactive features.** One commit per phase. **Never commit before human approval** — standing exception: pubspec version bumps auto-commit via `.claude/hooks/version-commit.js`. Messages: one line, plain phrasing, no attribution trailers.

## Meta — Maintaining This File
Keep under 100 lines. Bullets, imperative, WHY (constraint) then WHAT (rule). Only rules that prevent real mistakes; update immediately when architecture or versions change.
