# Arul — South Indian Wallpapers

Android-only Flutter app: Shorts-style wallpaper feed (static + live video), upload-your-content
(wallpaper-only), premium via PhonePe UPI Autopay. No ringtones. Backend: Cloudflare Workers + Neon + R2.
UI/UX is Arul's own design; backend architecture and logic are ported from the reference.

## State of this repo

**The app builds, installs and RUNS today** — verified on a Nothing Phone (1), Android 15.
It renders the real 428-wallpaper catalog straight from R2, filters by category, and gates
apply/share behind the paywall. What is NOT here yet is everything that needs a backend.

| Layer | State |
|---|---|
| UI / design system / navigation / l10n (6 locales) | **Done** — `flutter analyze` clean |
| Android platform (edge-to-edge, predictive back, themed icon, splash, R8, signing) | **Done** |
| Feed data | **Preview** — reads the bucket's `catalog/catalog.json` manifest over the public r2.dev URL |
| Live video playback | Placeholder — needs the native Media3 pool (port Phase 4) |
| Auth · premium · share · upload | Designed + gated, but stubbed — need the Worker (Phases 0–4) |

## Run it
```bash
flutter pub get
flutter run                                  # works with no config — uses the preview catalog
flutter run --dart-define-from-file=env/dev.json   # once provisioning is done
```

## Build it out
- Reference implementation (READ-ONLY, never modify): `c:\Anish\Pakiza`
- Plan: [docs/port-map.md](docs/port-map.md) — next up is **Phase 0** (provisioning)
- Cloud resources to create: [docs/provisioning.md](docs/provisioning.md)
- Behaviour that must not regress: [docs/edge-cases.md](docs/edge-cases.md)
- Design rules: [docs/ui-direction.md](docs/ui-direction.md)

## Kickoff prompt for a fresh Claude Code session
> Read CLAUDE.md, docs/port-map.md, docs/provisioning.md and docs/edge-cases.md. The reference
> implementation is c:\Anish\Pakiza — read-only, never modify it. The UI is already built and
> running; report which provisioning items are still open, then start Phase 0.

## Map
```
CLAUDE.md          session contract (read first)
docs/              architecture · data model · media rules · port plan · edge cases · provisioning · UI
lib/               app/{theme,widgets,l10n} · core/config · data/models · features/*
android/           edge-to-edge + predictive back + adaptive/themed icon + R8
.claude/           hooks (format, secret guard, version guards) + 6 skills
db/schema/         Neon schema (apply 01→03, then seed.sql)
workers/           wrangler.toml + package.json (src/ arrives in Phase 2)
env.example.json   → copy to env/dev.json + env/prod.json (git-ignored)
```
