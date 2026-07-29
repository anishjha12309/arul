# CLAUDE.md — Arul

> Read first, every session. Behaviour contracts: [docs/edge-cases.md](docs/edge-cases.md) · Backend: [docs/architecture.md](docs/architecture.md) · Media: [docs/media-conventions.md](docs/media-conventions.md) · Data: [docs/data-model.md](docs/data-model.md) · Infra inventory: [docs/provisioning.md](docs/provisioning.md) · Open defects: [docs/known-issues.md](docs/known-issues.md).

## 0. Sibling app — Pakiza (`c:\Anish\Pakiza`)
Peers, not parent and child. Most shared code came from Pakiza, but fixes flow BOTH ways — on 2026-07-29 five PhonePe/paywall hardening fixes went Arul → Pakiza. Read that repo when a shared behaviour is unclear; it encodes months of on-device fixes (decoder limits, PhonePe endpoint quirks, sweep safety).
**Fix a shared defect in BOTH repos in the same session.** Skipped one? Record it in that repo's `docs/known-issues.md`.
**Never sync these deliberate deltas:** `DKS_` order-id prefix (Pakiza's is `PKZ_`) · category browse, never All/New tabs (`type` is a rendering hint only) · ringtone cover art · 6 locales · own theming ([docs/ui-direction.md](docs/ui-direction.md)) · wallpaper-only user uploads. Identifiers are Arul's too: `com.hsrapps.arul`, `arul://`, `arul_*` storage keys, `Arul*` classes.

## 1. Project
**Arul** — Android-only (v1) South Indian wallpaper app. Flutter, Dart 3.12+. Shipping pillars: **Wallpapers** (Shorts-style feed, static + live video) · **Settings** (incl. upload-your-content, **wallpaper-only** — user submissions never accept audio). Premium gated via PhonePe UPI Autopay. Package `com.hsrapps.arul`. Support `support@hsrutility.com`. Privacy `https://hsrapps.com/arul/privacy-policy/`. Content: R2 bucket `south-indian-wallpapers` — devotional wallpapers (static + live interleaved) in 6 categories (Amman, Ayyappan, Murugan, Perumal, Sivan, Temples); **614 wallpapers, 0 ringtones** live as of 2026-07-29. **Never share a bucket/KV/DB with another app — the sweep would delete the other app's media.**
**Ringtones = PARKED for the v1 production release (2026-07-29).** No ringtone audio exists in the bucket, so the tab only ever showed "coming soon" — the entry point in `lib/app/router.dart` is commented out (with it, the two-tab shell and its dock) and `WRITE_SETTINGS` is commented out of the manifest. The BACKEND is untouched and stays that way: the worker still builds `catalog/ringtones/all_1.json`, `/media/signed-url` still accepts `kind='ringtone'`, and the `ringtones/` sweep prefix still protects audio + covers. `features/ringtones/**` and `app/shell/app_shell.dart` still compile and are still analyzed — do NOT delete them, and do not treat the missing tab as a defect. Grep `RINGTONES-PARKED`; un-park procedure in [docs/known-issues.md](docs/known-issues.md) + [docs/reference/ringtones-parked/README.md](docs/reference/ringtones-parked/README.md).

## 2. The One Architecture Rule
**Media-heavy, read-heavy. Cost = media egress.**
- **Media:** Cloudflare R2 (**zero egress**) + CDN `https://arul-cdn.hsrutility.com` — this is why it's affordable. Never serve media from the r2.dev origin: Cloudflare rate-limits it and caching/WAF do not apply there at all.
- **Browse feed:** edge-cached catalog JSON from the `build-catalog` Worker (CMS-triggered, or the hourly cron — [docs/cron.md](docs/cron.md)). **Never hits DB.**
- **DB (Neon Postgres via Hyperdrive):** per-user state only. Reached **only** from Workers — never the app.
- **Authoring:** unified CMS at `api.hsrutility.com/admin` — **separate worker `hsr-cms`, separate repo** (`c:\Anish\Unified CMS`, github.com/anishjha12309/hsr-cms); manages Arul AND Pakiza from one login, reaching each app's worker via service binding + `/internal/build-catalog`. Row write + `content_version` bump + rebuild + purge, atomically. Near-instant updates via `catalog/version.json` + `?v=`. **This repo's worker has no `/admin`.**
- **No server-side transcoding.** ffmpeg locally per [docs/media-conventions.md](docs/media-conventions.md).

## 3. Stack (decided — do NOT re-litigate; versions pinned in pubspec.yaml / workers/package.json)
**Before implementing ANY package, fetch its pub.dev / vendor docs. Never code from memory.**
| Concern | Choice |
| --- | --- |
| State / Nav | Riverpod 3 (riverpod_generator) · go_router |
| Backend | Cloudflare Workers (Hono, TS) = API + crons at `https://arul-api.hsrutility.com` · Neon via Hyperdrive · Workers KV · R2. Code in `workers/`. |
| Auth | Google one-tap (`google_sign_in` v7: instance → initialize → authenticate) → Worker verifies idToken (`aud` = WEB client id) → identity-only JWT (**60m access** + 60d rotating refresh) |
| Payments | PhonePe v2 Autopay (OAuth), server calls in Workers only. One trial per user (`trial_end` = consumed-marker); repeat = ₹199 TRANSACTION setup. Endpoint facts: [docs/phonepe.md](docs/phonepe.md) — read there, never from memory. |
| Analytics | `AnalyticsService` → Composite = PostHog (~5% user panel, **four allow-listed events**) + GA4/`firebase_analytics` (**every event at 100% = the complete record**; ★→`login`/`purchase`) + Meta (★ only). **Never call SDKs from widgets.** Revenue truth = Neon, never PostHog. [docs/analytics-events.md](docs/analytics-events.md) |
| Crash/Perf | Crashlytics + Performance behind `CrashReporter`/`PerformanceMonitor`; run in all real builds, only `flutter test` skips. Needs git-ignored `android/app/google-services.json`. |
| Video | Native Media3 ExoPlayer texture pool (`FeedVideoPlugin` platform channel) — players REUSED across clips (setMediaItem swap, never dispose+recreate). Live MP4 from CDN; shimmer until first frame; no posters. |

## 4. Layout
Feature-first; Riverpod providers are the only cross-layer glue. App reaches the backend only via `lib/core/api/api_client.dart`.
```
lib/  main.dart · app/ · core/{config,api,error,analytics} · features/{auth,wallpapers,ringtones,premium,referral,upload,settings} · data/{models,repositories}
workers/  Worker API + crons (TS)     db/schema/  apply 01→04, then seed.sql     docs/  reference docs
```

## 5. Premium Entitlement — THE Cross-Cutting Rule
`isPremium` = (status ∈ {trialing, active, **cancelled**} AND `current_period_end > now`) OR `users.reward_premium_until > now`. `cancelled` keeps premium until period end; `paused`/`expired` get none. **Entitlement is NEVER authoritative in the JWT** — the `prm` claim is a UI hint only; gated actions live-read Neon so purchase/expiry/refund apply instantly.
**Gated (ALL content is premium):** wallpaper apply + share · ringtone set. **Always free:** browse, preview (incl. ringtone audio preview from CDN). Media keys are public BY DESIGN (soft gate); the real gate is Worker `/media/signed-url` → live entitlement check → short-lived signed URL. Client gate `ensurePremium()` must **await** `entitlementProvider.future` (a loading snapshot must never bounce a premium user), track `${action}_blocked_premium`, route `/premium?source=`.
Re-applying or re-sharing an already-cached wallpaper still calls the gate — a cache must never become a permanent licence. Offline with bytes on disk is the one allowed pass-through.

## 5b. Browse Model — category, never type
`category` (amman·ayyappan·murugan·perumal·sivan·temples) is THE browse axis for wallpapers AND ringtones: chips filter by category, static + live interleave inside each one. **Never filter/tab by static vs live** (`type` is a rendering hint). R2 keys are category-partitioned (`wallpapers/<category>/…`). Categories are free text: a new one is an insert, not a migration.

## 6. Localization
6 languages (ARB, `gen_l10n`): `en, ta, te, kn, ml, hi`. Only UI chrome localized; server content as-authored.

## 7. Theming
Light / Dark / System, persisted. Fixed brand seed — **extracted from the splash video** (`assets/video/splash.mp4`): lotus rose primary, teal secondary, temple gold accent, plum-black ink. ALL colors via `lib/app/theme/tokens.dart` — no literal `Color(0x…)` in screens. Schemes are hand-specified, NOT `ColorScheme.fromSeed` (it invents its own secondary/tertiary and loses the video's actual teal + gold). **Never seed from device wallpaper / dynamic color.**

## 8. Known Gotchas (MUST hold — full checklist in docs/edge-cases.md)
1. Live video files: **1024×1824 only** (w%128==0, h%32==0, fits 1088×1920 hw-decoder cap) — anything else hits the green-edge / software-decode bug class on budget SoCs.
2. Android 12+ wallpaper-apply restart: manifest `configChanges` includes `uiMode|colorMode` + `onConfigurationChanged` + dark launch theme. Apply must never cold-restart the app.
3. Sign-in auto-launches FULL `authenticate()` on first frame — NEVER swap to lightweight/silent auth (retention decision).
4. PhonePe: notify user 24h before each debit (hourly cron); SDK order token + the working cancel path are in [docs/phonepe.md](docs/phonepe.md).
5. Hyperdrive query caching stays OFF (caused ~60s staleness).
6. Stale catalog ≠ cache bug: fix by rebuilding, never by purging. Cache behaviour + its traps: [docs/caching.md](docs/caching.md).

## 9. Secrets & Environment
**Never hardcode keys.** App: `--dart-define-from-file=env/dev.json` (git-ignored; template `env.example.json`). Worker: `npx wrangler secret bulk <file.json>` — never a shell pipe, a trailing newline in `PHONEPE_ENV` silently routes prod credentials to the sandbox host. Local dev `workers/.dev.vars` (git-ignored, holds `DATABASE_URL` too). `.gitignore` covers `env/`, keystores, `key.properties`, `google-services.json`, `.dev.vars`. `TRIAL_TOMBSTONE_SECRET`: set once, **NEVER rotate** (rotation orphans tombstones and re-opens trial farming).

## 10. Commands
```bash
flutter pub get && dart run build_runner watch -d     # codegen
flutter gen-l10n && flutter analyze && flutter test
flutter run --dart-define-from-file=env/dev.json
cd workers && npm i && npx tsc --noEmit && npx vitest run
npx wrangler deploy                                   # deploy IS part of done for workers/
curl -X POST https://arul-api.hsrutility.com/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
```

## 11. Definition of Done & Git
Checklist: `.claude/skills/phase-completion/`. **Quick:** `flutter analyze` clean + formatted · worker `tsc`+tests green **+ deployed** · loading/empty/error states · localized edge cases · analytics fire · no secrets. **No tests for premium/payments/inactive features.** One commit per phase. **Never commit before human approval** — standing exception: pubspec version bumps auto-commit via `.claude/hooks/version-commit.js`. Messages: one line, plain phrasing, no attribution trailers.
**The `.aab` is the only guarded artifact** (it is the only one Play ever sees). Three hooks fire on it and on nothing else, so APK builds stay free for on-device testing: `release-flag-secure-guard.js` denies the build unless an ACTIVE `setFlags(FLAG_SECURE)` survives in `MainActivity.kt` · `release-version-guard.js` denies it when the pubspec version was already built from different source, and only an `.aab` landing consumes a bump · `release-commit-reminder.js` reminds you to commit the source a successful release build compiled (`.aab`, or `flutter build apk --release`).

## Meta — Maintaining This File
Keep under 100 lines; no doc in `docs/` or `workers/README.md` may exceed it either — split instead, and link the split with a one-line "read this when…". Bullets, imperative, WHY (constraint) then WHAT (rule). Only rules that prevent real mistakes; update immediately when architecture or versions change.
