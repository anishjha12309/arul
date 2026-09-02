# CLAUDE.md — Arul

<!-- 8 KB cap; budgets and house style: .claude/skills/doc-update/SKILL.md. Section numbers are
cited by hooks, rules and code comments (grep "CLAUDE.md §" before renumbering). -->

Session contract: what every task needs regardless of the files it touches. Per-area invariants
live in `.claude/rules/*.md` and load only when you read a matching file; the traps behind them are
in `docs/` (§9). Open defects: `docs/known-issues.md`.

## 0. Sibling app — Pakiza (`c:\Anish\Pakiza`)

- Peers, not parent and child. Workers, entitlement, crons, catalog build, PhonePe, R2 conventions
  and analytics gating are shared behaviour and fixes flow both ways: fix a shared defect in BOTH
  repos in the same session, or add a line to that repo's `docs/known-issues.md`.
- Never sync these deliberate deltas: `DKS_` order-id prefix (Pakiza `PKZ_`) · category browse,
  never All/New tabs · ringtone cover art · 6 locales · Arul's own theming · category-partitioned
  upload keys (Pakiza's are flat). Identifiers stay Arul's: `com.hsrutility.arul`, `arul://`,
  `arul_*` storage keys, `Arul*` classes.
- Two owner-decided exceptions: `android/**/wallpaper/**` is byte-identical to Pakiza's modulo
  identifiers (keep them in step → `.claude/rules/wallpaper-apply.md`), and `ArulEarnButton` is a
  port of Pakiza's `EarnChip` with only the gold changed. Everything else on screen is Arul's own.

## 1. Project

- Android-only Flutter app, package `com.hsrutility.arul`: South Indian devotional wallpapers
  (static + live video feed) and ringtones; premium via PhonePe UPI Autopay.
- Three-tab shell behind the floating dock (Wallpapers · Ringtones · Settings). **Settings is a dock
  branch, not a pushed route.** Reminders are on-device only: no push, and no screen may promise one.
- Content lives in the R2 bucket `south-indian-wallpapers`. **Never share a bucket, KV namespace or
  database with another app** — the orphan sweep deletes the other app's media.

## 2. Architecture — media-heavy, read-heavy, cost = media egress

- Media: R2 (zero egress) behind the CDN custom domain.
- Browse feed: edge-cached catalog JSON from the `build-catalog` Worker. **It never hits the DB.**
- DB: Neon via Hyperdrive, per-user state only, reached **only** from Workers — never from the app.
- Authoring: the unified CMS is a separate worker and repo (`hsr-cms`, `c:\Anish\Unified CMS`)
  serving Arul and Pakiza. **This repo's worker has no `/admin`.**
- No server-side transcoding — ffmpeg locally per `docs/media-conventions.md`.

## 3. Stack — decided, do not re-litigate

Versions are pinned in `pubspec.yaml` and `workers/package.json`. **Before implementing any package,
fetch its pub.dev or vendor docs; never code an API from memory.**

- State / nav: Riverpod (riverpod_generator) · go_router.
- Backend: Cloudflare Workers (Hono, TS) in `workers/` = API + crons · Neon via Hyperdrive · KV · R2.
- Auth: Google Credential Manager → Worker verifies the ID token and nonce → identity-only JWT.
- Payments: PhonePe v2 Autopay (OAuth); server calls in Workers only. One trial per user; a repeat
  is a full-price TRANSACTION setup.
- Analytics: `AnalyticsService` → PostHog (journey allow-list) + GA4 (everything, the complete
  record) + Meta (★ only). **Never call an SDK from a widget.** Revenue truth is Neon.
- Crash / perf: Crashlytics + Performance behind `CrashReporter` / `PerformanceMonitor`; only
  `flutter test` skips them. Needs a git-ignored `google-services.json`.
- Video: native Media3 ExoPlayer texture pool over a platform channel; players are reused.

## 4. Layout

Feature-first; Riverpod providers are the only cross-layer glue; the app reaches the backend only
through `lib/core/api/api_client.dart`.

## 5. Premium entitlement

**All content is premium** (wallpaper apply + share, ringtone set); browse and preview are always
free, and media keys are public by design — the gate is the Worker's live entitlement read. The rule
has ONE home, `premiumPredicate` in `workers/src/lib/entitlement.ts`; never re-derive it
client-side → `docs/architecture.md` §Entitlement.

## 5b. Browse model

**`category` is THE browse axis** on both tabs; `type` (static/live) is a rendering hint that never
becomes a filter or a tab; categories are free text, so a new one is an insert, not a migration.
Order is ONE SQL clause in `build-catalog`, numbered into the catalog's `feed_rank` so it reaches
installs that never update. Hand pins lead it (`feed_rank ASC NULLS LAST`, NULL = unpinned), then
lifetime uses, then recency, then `id`. No score → `docs/browse.md`.

## 6. Secrets & environment

- Never hardcode a key. App: `--dart-define-from-file=env/dev.json` (git-ignored; template
  `env.example.json`). Worker: `npx wrangler secret bulk <file.json>`, **never a shell pipe** — a
  trailing newline once routed production credentials to the sandbox host, and every other secret
  is still compared untrimmed. Local dev: `workers/.dev.vars`.
- **`TRIAL_TOMBSTONE_SECRET`: set once, never rotate** — rotation orphans every tombstone and
  re-opens trial farming.
- `guard-secrets.js` denies any git command that names `env/`, a keystore, `key.properties`,
  `google-services.json` or `.dev.vars`. A denial is the hook working — unstage, don't work around.

## 7. Commands

```bash
flutter pub get && dart run build_runner watch -d      # codegen — generated files are TRACKED
flutter analyze && flutter test
flutter run --dart-define-from-file=env/dev.json
cd workers && npx tsc --noEmit && npx vitest run && npx wrangler deploy   # deploy IS part of done
```

## 8. Definition of done & git

- Done = `flutter analyze` clean and formatted · worker `tsc` + vitest green **and deployed** ·
  loading, empty and error states · localized edge cases · analytics fire · no secrets. Full
  checklist: `.claude/skills/phase-completion/`.
- One commit per phase; message one line, plain, no attribution trailers. **Never commit before
  human approval.** The one exception is the pubspec version bump, which `version-commit.js`
  auto-commits with `git add -A` — so land the phase commit first.
- The `.aab` is the only guarded artifact; APK builds stay free for on-device testing →
  `.claude/rules/hooks-release.md`.

## 9. Docs — read the routed doc before touching its area

The `[doc-sync]` hook names the doc for any file you edit: read it before debugging (the answer is
usually already there) and update it through the `doc-update` skill. Each entry below is
`docs/<name>.md`. Two are not obvious: **edge-cases** indexes every regression contract — walk it
before a release — and **architecture** covers routes, entitlement, uploads and the catalog build.

edge-cases · architecture · data-model · browse · ringtones · auth · launch-surface · phonepe ·
autopay-debits · cron · caching · media-conventions · video-feed · wallpaper-apply ·
analytics-events · analytics-ops · google-ads · deep-links · deferred-links · share ·
notifications · ui-direction · perf-measurement

## Compact instructions

Preserve: the list of modified files, the outcome of every gate that ran, and the path of any ledger
or report being written.

## House style for this file and `docs/`

One home per fact, pointers everywhere else. No calendar dates (git log is provenance; keep only
durations that ARE the rule), no done-logs, nothing readable from the code or the running app.
Budgets, house style and the rule/ROUTES contract: `.claude/skills/doc-update/`.
