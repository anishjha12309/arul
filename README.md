# Arul — South Indian Wallpapers & Ringtones

Android-only Flutter app: Shorts-style wallpaper feed (static + live video), category-browsed
ringtones with cover art, upload-your-content (wallpaper-only), premium via PhonePe UPI Autopay.
Backend: Cloudflare Workers + Neon + R2. UI/UX is Arul's own design. Shares most of its backend and
logic with its sibling app Pakiza (`c:\Anish\Pakiza`) — fixes flow both ways; see CLAUDE.md §0.

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
| Custom domains | Live — API `arul-api.hsrutility.com`, media CDN `arul-cdn.hsrutility.com` |
| Content | 614 wallpapers · 0 ringtones (no ringtone content published yet) |

Still open: **FLAG_SECURE** is not added yet — see [docs/known-issues.md](docs/known-issues.md).

## Run it
```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json   # env/ is git-ignored — copy env.example.json
```

## Work on it
- Session contract, incl. the deltas vs Pakiza that must never be synced away: [CLAUDE.md](CLAUDE.md)
- Behaviour that must not regress: [docs/edge-cases.md](docs/edge-cases.md)
- Backend: [docs/architecture.md](docs/architecture.md) · [workers/README.md](workers/README.md) · [docs/cron.md](docs/cron.md) · [docs/phonepe.md](docs/phonepe.md)
- Design rules: [docs/ui-direction.md](docs/ui-direction.md)
- Content authoring = the unified CMS at `api.hsrutility.com/admin` — a **separate worker and
  repo** (`c:\Anish\Unified CMS`). This repo's worker has no `/admin`.

## Map
```
CLAUDE.md          session contract (read first)
docs/              architecture · data model · media rules · edge cases · caching · cron · phonepe · analytics · provisioning · UI
lib/               app/{theme,widgets,l10n} · core/{config,api,error,analytics} · data/* · features/*
android/           edge-to-edge + predictive back + adaptive/themed icon + R8 + release signing
.claude/           hooks (format, secret guard, version guards) + 8 skills
db/schema/         Neon schema (apply 01→04, then seed.sql)
workers/           Worker API + crons (src/, wrangler.toml)
tools/             content-import — bulk wallpaper import pipeline
env.example.json   → copy to env/dev.json + env/prod.json (git-ignored)
```
