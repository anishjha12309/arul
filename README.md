# Arul — South Indian Wallpapers

Android-only Flutter app: Shorts-style wallpaper feed (static + live video), category browse,
ringtones, upload-your-content (wallpaper-only), premium via PhonePe UPI Autopay. Backend:
Cloudflare Workers + Neon + R2. UI/UX is Arul's own design. Shares most of its backend and logic
with its sibling app Pakiza (`c:\Anish\Pakiza`) — fixes flow both ways; see CLAUDE.md §0.

## State of this repo

**Live.** The backend has been in production since 2026-07-14 and the app runs against it: real
catalog (wallpapers + ringtones), Google sign-in, PhonePe (PRODUCTION credentials), Firebase
analytics + Crashlytics. Package `com.hsrutility.arul` on the business Play account — the
pre-rename listing is retired.

`FLAG_SECURE` is set app-wide, but only on the **Play-installed** build (`MainActivity.onCreate`):
an AAB can only reach a device through Play, so that is the runtime proxy for "this is the shipped
artifact". Debug and sideloaded release APKs stay screenshottable for the Play listing. A hook denies
any `.aab` build that loses it. Open items: [docs/known-issues.md](docs/known-issues.md).

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
docs/              constraints only: edge cases · architecture · data model · media · caching · cron · phonepe · analytics · share · notifications · UI
lib/               app/{theme,widgets,shell,l10n} · core/{config,api,error,analytics} · data/* · features/*
android/           edge-to-edge + predictive back + adaptive/themed icon + R8 + release signing
.claude/           hooks (doc-sync, format, secret guard, .aab guards) + project skills
db/schema/         Neon schema — apply *.sql in filename order, then seed.sql
workers/           Worker API + crons (src/, wrangler.toml)
tools/             content-import — bulk wallpaper + ringtone import pipeline
env.example.json   → copy to env/dev.json + env/prod.json (git-ignored)
```
