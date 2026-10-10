# CLAUDE.md — Arul

What every session needs. Area invariants live in `.claude/rules/*.md` and load when you read a
matching file; the reasoning behind them is in `docs/` (§8). Open defects: `docs/known-issues.md`.

## 1. Product

Android-only Flutter app, package `com.hsrutility.arul`: South Indian devotional wallpapers (static
and live), ringtones and status clips (video with music), premium via PhonePe UPI Autopay. Dock:
Wallpapers · Ringtones · Status, all three fixed (never gated on the remote config); **Settings
is a pushed route from the header gear, never a dock branch.** No screen promises a push or a
reminder — campaign pushes come only from the CMS through the Worker.

- **All content is premium** (apply, share, set, save); browse and preview are free and media keys are
  public by design. The gate is the Worker's live entitlement read, whose rule has ONE home,
  `premiumPredicate` in `workers/src/lib/entitlement.ts` — never re-derive it client-side.
- **`category` is THE browse axis** on every tab; `type` (static/live) is a rendering hint, never a
  filter or a tab. Categories are free text, so a new one is an insert, not a migration. Feed order is
  one SQL clause in `build-catalog`, numbered into the catalog's `feed_rank`.

## 2. Architecture — media-heavy, read-heavy, cost = media egress

- Media in R2 bucket `south-indian-wallpapers` behind the CDN domain (zero egress). **Never share a
  bucket, KV namespace or database with another app** — the orphan sweep deletes what it does not
  recognise.
- Browse feed = edge-cached catalog JSON from the `build-catalog` cron. **It never hits the DB.**
- Neon (via Hyperdrive) holds per-user state only and is reached **only from Workers**, never from
  the app. The app reaches the backend only through `lib/core/api/api_client.dart`.
- Authoring is the separate `hsr-cms` Worker and repo (`~/Anish/Unified CMS`). **This repo's Worker
  has no `/admin`.** No server-side transcoding: ffmpeg locally per `docs/media-conventions.md`.

## 3. Stack — decided, do not re-litigate

Versions are pinned in `pubspec.yaml` and `workers/package.json`. **Fetch the pub.dev or vendor docs
before using any package API; never code one from memory.**

- Riverpod (`riverpod_generator`) + go_router, feature-first layout; providers are the only
  cross-layer glue.
- Cloudflare Workers (Hono, TypeScript) in `workers/` = API + crons · Neon · KV · R2.
- Auth: Google Credential Manager → Worker verifies ID token + nonce → identity-only JWT. Google
  sign-in is the only door.
- Payments: PhonePe v2 Autopay, server calls in Workers only. One trial per user ever.
- Analytics through `AnalyticsService` only — PostHog (journey allow-list) + GA4 (everything) + Meta
  (conversions). **Never call an SDK from a widget.** Revenue truth is Neon.
- Crashlytics + Performance behind `CrashReporter` / `PerformanceMonitor`; needs a git-ignored
  `google-services.json`. Video: native Media3 ExoPlayer texture pool over a platform channel.

## 4. Secrets

- Never hardcode a key. App: `--dart-define-from-file=env/dev.json` (git-ignored; template
  `env.example.json`) — **`dev.json` points at the LIVE Worker.** Worker: `npx wrangler secret bulk
  <file.json>`, never a shell pipe (a trailing newline once routed production to the sandbox host).
  Local dev: `workers/.dev.vars`, whose Hyperdrive string is the Neon `debug` branch, never prod.
- **`TRIAL_TOMBSTONE_SECRET` is set once and never rotated** — rotation re-opens trial farming.
- The `guard-secrets` hook denies any git command that names `env/`, a keystore, `key.properties`,
  `google-services.json` or `.dev.vars`. A denial is the hook working: unstage, do not work around.

## 5. Dev loop and gates

```bash
flutter pub get && dart run build_runner build -d      # generated files are TRACKED
flutter analyze && flutter test                        # the gate, ~5 min cold — see below
flutter run --dart-define-from-file=env/dev.json
cd workers && npm run check && npx tsc --noEmit && npx vitest run && node tools/deploy-safe.mjs   # deploy IS part of done
```

Iterate on the Dart MCP's `analyze_files` (instant, same analysis server) and run `flutter analyze`
once at the phase end; the `dart-analyze-gate` Stop hook holds a turn that edited Dart until one of
them ran. `dart format` runs itself on every edit. JS/TS is the same: Biome (root `biome.jsonc`) fixes
every edited file, and a turn that edited JS/TS is held until `biome check` + workers `tsc` pass
(`ts-check` hook). Device work: the `on-device` skill.

## 6. Definition of done and git

Done = `flutter analyze` clean · `flutter test` green · worker `check` + `tsc` + vitest green **and deployed
through `tools/deploy-safe.mjs`** · loading, empty and error states · localized edge cases ·
analytics fire · no secrets. Checklist: the `phase-completion` skill.

One commit per phase, one-line plain message, no attribution trailers. **Never commit before the
owner approves.** The one exception is the pubspec version bump, which `version-commit` auto-commits
with `git add -A` — so land the phase commit first. The `.aab` is the only guarded artifact
(`.claude/rules/hooks-release.md`).

## 7. Product changes need the owner

Anything a user would notice — copy, flow, pricing, a new event, a new sheet — is the owner's call.
Ask, or state the assumption and stop before building it.

## 8. Docs

The `[doc-sync]` hook names the doc for any file you edit: read it before debugging (the answer is
usually there) and update it through the `doc-update` skill, which carries the house style and byte
budgets. `docs/edge-cases.md` + `edge-cases-reel.md` index every regression contract; walk both pre-release.
`docs/architecture.md` covers routes, entitlement, uploads and the catalog build. Suspect a doc is
stale? `/doc-audit <name>`.

## Compact instructions

Preserve the list of modified files, the outcome of every gate that ran, and the path of any ledger
or report being written.
