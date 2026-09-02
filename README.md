# Arul — South Indian Wallpapers

Android-only Flutter app: a Shorts-style wallpaper feed (static + live video), category browse,
ringtones, upload-your-content, and premium via PhonePe UPI Autopay. Backend: Cloudflare Workers +
Neon + R2. The UI is Arul's own design. It shares most of its backend and logic with its sibling app
Pakiza — fixes flow both ways; see [CLAUDE.md](CLAUDE.md) §0.

**The session contract is [CLAUDE.md](CLAUDE.md)** — read that first. It carries the architecture
rule, the deltas from Pakiza that must never be synced away, the definition of done, and a table of
which doc to read when. Area invariants load themselves from `.claude/rules/` as you open files.

## Run it
```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json   # env/ is git-ignored — copy env.example.json
```

Open defects and traps already paid for: [docs/known-issues.md](docs/known-issues.md).

`FLAG_SECURE` is set app-wide, but only on the **Play-installed** build: an AAB can only reach a
device through Play, so that is the runtime proxy for "this is the shipped artifact". Debug and
sideloaded release APKs stay screenshottable for the Play listing, and a hook denies any `.aab` that
loses the flag.

Content authoring is the unified CMS at `api.hsrutility.com/admin` — a **separate worker and repo**
(`c:\Anish\Unified CMS`). This repo's worker has no `/admin`.
