---
description: The .aab is the only guarded artifact.
paths:
  - ".claude/hooks/**"
  - "android/app/src/main/AndroidManifest.xml"
  - "android/app/build.gradle.kts"
---

**The `.aab` is the only guarded artifact** — it is the only one Play ever sees, so APK builds stay
free for on-device testing and never consume a version. Three hooks watch it:

- `release-flag-secure-guard.js` DENIES the build unless an ACTIVE `setFlags(FLAG_SECURE)` survives
  in `MainActivity.kt`; one that exists only inside a comment does not count.
- `release-version-guard.js` DENIES it when the pubspec version was already built from different
  source. Only an `.aab` landing consumes a bump.
- `release-commit-reminder.js` reminds you to commit the source a successful release build compiled.

Manifest invariants:

- **`FLAG_SECURE` is set in `MainActivity.onCreate`, not the manifest** — it must survive the Android
  12+ wallpaper-apply recreate — and **only when `isPlayInstall()`**, which fails CLOSED. So a
  sideloaded release APK deliberately differs from the store build: screenshots work. Intended.
- **`WRITE_SETTINGS` must stay an ACTIVE line.** Ringtones ship; a commented one breaks Set on every
  device. It is special-access and shows on the Play listing, so the Data safety form and the listing
  copy must both account for it.
- **`configChanges` must keep `uiMode|colorMode`** or wallpaper apply cold-restarts the app.
- Intent-filters are never merged across schemes ([docs/deep-links.md](../../docs/deep-links.md)).

**ABI rule:** the bundle stays whole (all three ABIs, the default — never `--split-per-abi` or
`--target-platform` on an appbundle); every APK is arm64-only.

Every hook is a module that `run.js` calls once per event (one process per Bash call, not four); a
module that throws is skipped silently, so a broken hook fails OPEN. After editing one, `node --check`
it and pipe a payload through `node .claude/hooks/run.js <pre-bash|post-edit|post-bash|stop>` with
`CLAUDE_PROJECT_DIR` set. CLAUDE.md §6 and the `release-build` skill make claims about what these
hooks enforce.
