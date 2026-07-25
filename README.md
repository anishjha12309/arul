# Arul — South Indian Wallpapers & Ringtones

Android-only Flutter app: Shorts-style wallpaper feed (static + live video), category-browsed
ringtones with cover art, upload-your-content (wallpaper-only), premium via PhonePe UPI Autopay.
Backend: Cloudflare Workers + Neon + R2. UI/UX is Arul's own design; backend architecture and
logic are ported from the reference (`c:\Anish\Pakiza`, READ-ONLY — never modify it).

## State of this repo

**Shipped.** v1.0.0+20 is built, signed and uploaded to the Play Console — not public yet.
The backend has been live since 2026-07-14 and the app runs against production: real catalog,
Google sign-in, PhonePe (PRODUCTION credentials), Firebase analytics + Crashlytics.

| Layer | State |
|---|---|
| UI / design system / navigation / l10n (6 locales) | Done — `flutter analyze` clean |
| Android platform (edge-to-edge, predictive back, themed icon, splash, R8, release signing) | Done |
| Feed data | Live — per-scope `catalog/<scope>/all_N.json` from the `build-catalog` Worker |
| Live video playback | Done — native Media3 texture pool (`FeedVideoPlugin`) |
| Auth · premium · share · upload · ringtones | Done |
| Content | 514 wallpapers · 0 ringtones (no ringtone content published yet) |

Still open: **FLAG_SECURE** is not added yet (docs/edge-cases.md). Custom domains
`arul-api` / `arul-cdn.hsrutility.com` are **not attached** — the live origins are the
`*.workers.dev` API and the `*.r2.dev` CDN (see workers/README.md).

## Run it
```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json   # env/ is git-ignored — copy env.example.json
```

## Work on it
- Session contract: [CLAUDE.md](CLAUDE.md) — read first, every session
- What got built and the deltas vs the reference: [docs/port-map.md](docs/port-map.md)
- Behaviour that must not regress: [docs/edge-cases.md](docs/edge-cases.md)
- Backend: [docs/architecture.md](docs/architecture.md) · [workers/README.md](workers/README.md)
- Design rules: [docs/ui-direction.md](docs/ui-direction.md)
- Content authoring = the unified CMS at `api.hsrutility.com/admin` — a **separate worker and
  repo** (`c:\Anish\Unified CMS`). This repo's worker has no `/admin`.

## Map
```
CLAUDE.md          session contract (read first)
docs/              architecture · data model · media rules · port plan · edge cases · provisioning · UI
lib/               app/{theme,widgets,l10n} · core/{config,api,error,analytics} · data/* · features/*
android/           edge-to-edge + predictive back + adaptive/themed icon + R8 + release signing
.claude/           hooks (format, secret guard, version guards) + 6 skills
db/schema/         Neon schema (apply 01→04, then seed.sql)
workers/           Worker API + crons (src/, wrangler.toml)
tools/             content-import — bulk wallpaper import pipeline
env.example.json   → copy to env/dev.json + env/prod.json (git-ignored)
```
