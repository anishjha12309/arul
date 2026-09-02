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
  sideloaded release APK deliberately differs from the store build in two visible ways: screenshots
  work, and the reminders screen shows its QA card. Both are intended.
- **`WRITE_SETTINGS` must stay an ACTIVE line.** Ringtones ship; a commented one breaks Set on every
  device. It is special-access and shows on the Play listing, so the Data safety form and the listing
  copy must both account for it.
- **`configChanges` must keep `uiMode|colorMode`** or wallpaper apply cold-restarts the app.
- Intent-filters are never merged across schemes ([docs/deep-links.md](../../docs/deep-links.md)).

**ABI rule:** the bundle stays whole (all three ABIs, the default — never `--split-per-abi` or
`--target-platform` on an appbundle); every APK is arm64-only.

Never casually edit the logic of `guard-secrets`, `version-commit`, `release-*` or `format-dart` —
CLAUDE.md §8 and the `release-build` skill make claims about what they enforce. `node --check` every
hook after an edit.
