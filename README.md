# Arul — South Indian Wallpapers

Android-only Flutter app: a Shorts-style wallpaper feed (static + live video), category browse,
ringtones, user uploads, and premium via PhonePe UPI Autopay. Backend: Cloudflare Workers + Neon + R2
(`workers/`). Content authoring is the separate `hsr-cms` Worker (`~/Anish/Unified CMS`); this
repo's Worker has no `/admin`.

Working in this repo with an agent: [CLAUDE.md](CLAUDE.md) is the session contract, `.claude/rules/`
loads the per-area invariants as files are opened, and `docs/` holds the reasoning behind them.
Open defects: [docs/known-issues.md](docs/known-issues.md).

## Run it

```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json   # env/ is git-ignored — copy env.example.json
```

Release builds, signing and the Play upload: `.claude/skills/release-build/`. The Worker's own README
is [workers/README.md](workers/README.md).
