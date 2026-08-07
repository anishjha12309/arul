---
name: release-build
description: Build and verify the signed Arul release AAB/APK for Play. Use for release builds, signing checks, or Play-upload prep.
---

# Release Build

0. **Hooks gate the `.aab` only** — it is the only artifact Play ever sees, so APK builds stay free
   for on-device testing and never consume a version.
   - `release-version-guard.js` BLOCKS an `.aab` whose pubspec version was already built from
     different source (state: git-ignored `.claude/last-release-build.json`). If blocked: bump
     `version:` in pubspec.yaml (+1 build number) and retry. Only an `.aab` landing records the
     bump as spent — a subsequent APK from the same source is free.
   - `release-flag-secure-guard.js` BLOCKS an `.aab` unless an ACTIVE `setFlags(FLAG_SECURE)`
     survives in `MainActivity.kt`; one that only exists inside a comment does not count. The call
     sits behind `isPlayInstall()` (installer == `com.android.vending`, failing CLOSED), so the
     shipped AAB blocks screenshots and screen recording while sideloaded release APKs stay
     capturable for listing screenshots and on-device debugging.
   - `release-commit-reminder.js` reminds you to commit after a successful release build left
     source uncommitted (an artifact is only reproducible if its source is in git).

   `isPlayInstall()` now has a SECOND consumer besides FLAG_SECURE: the reminders screen's
   notification QA tools (`qaToolsEnabled`). So a sideloaded release APK deliberately differs from
   the store build in two visible ways — screenshots work, and Settings → Reminders shows a TESTING
   card. Both are intended; neither reaches a Play user. See docs/notifications.md.

   All three match the command pattern anywhere in a string, so avoid echoing "flutter build
   appbundle" literally in an unrelated command.
1. **ABI rule — the bundle stays whole, every APK is split. No exceptions.**
   - **AAB (the Play artifact): all three ABIs in ONE bundle**, which is the default —
     ```bash
     flutter build appbundle --release --dart-define-from-file=env/prod.json
     ```
     NEVER pass `--split-per-abi` or `--target-platform` here. Play generates the per-device
     split itself from the bundle; stripping an architecture out of the upload means every device
     on that ABI simply cannot install, and it is invisible until a real user hits it.
   - **APKs, release AND debug: arm64-v8a ONLY** (owner's call, 2026-07-30 — the other two are
     noise). `--split-per-abi` names the file per ABI, `--target-platform` builds just the one:
     ```bash
     flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define-from-file=env/prod.json
     flutter build apk --debug   --split-per-abi --target-platform android-arm64 --dart-define-from-file=env/dev.json
     ```
     The ONLY output is `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (~26 MB, vs 61 MB
     fat). No `app-release.apk` is written — anything pointing at that path must be updated.
     Two consequences, both fine because they touch sideloading only and never Play (the AAB still
     ships all three ABIs, so no real user is affected):
     · a 32-bit-only phone cannot install it — irrelevant, arm64 has been universal since ~2017;
     · **a Windows x86_64 emulator cannot install it either.** To test a release build on an
       emulator, rebuild with `--target-platform android-x64` for that run only.
     Do NOT add `--target-platform` to the appbundle command to match — see the AAB bullet above.
2. Signing preconditions: `android/key.properties` + keystore `C:\Users\anish\arul-upload.jks`
   (alias `arul`; passwords in the user's password manager — never ask to paste them into chat).
   **Missing key.properties silently falls back to DEBUG signing** — always verify. Which tool
   depends on the artifact:
   - **AAB** (carries a v1 JAR signature):
     ```bash
     jarsigner -verify -certs -verbose build/app/outputs/bundle/release/app-release.aab | grep "CN="
     ```
   - **APK** — Flutter signs these **v2-only, with no v1 block**, so `jarsigner` and
     `keytool -printcert -jarfile` print NOTHING and read as a broken build. Use apksigner:
     ```bash
     "$LOCALAPPDATA/Android/Sdk/build-tools/36.0.0/apksigner.bat" verify --print-certs \
       build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
     ```
   Must show `CN=HSR Apps`. `CN=Android Debug` = NOT release-signed; stop.
3. Sanity: check dart-defines took effect via `aapt dump badging` on an APK if in doubt.
4. Play upload = user task (Play App Signing ON). **v1.0.0+20 went to the OLD pre-rename listing** — retired by the 2026-08 package rename; the `com.hsrutility.arul` app on the business account starts with no uploads (PACKAGE-RENAME-PLAN.md).
   SHA-1/256 registration — BOTH the app-signing and upload certs (Play Console → Setup → App
   signing) in the Google Cloud OAuth Android client + Firebase — is required after the first
   upload, or Google Sign-In is broken for testers. That state lives in Play Console, so confirm it
   there; re-check only if the upload key rotates. No rebuild needed either way.
5. Before the app goes PUBLIC: privacy policy live ✓
   (`https://hsrutility.com/privacy/` — the shared company page), PhonePe PROD webhook registered ✓, real analytics
   creds in env/prod.json ✓, FLAG_SECURE ✓ (Play-install-gated, guard-enforced — v1.0.0+20 shipped
   without it, so the first public build must be newer).
6. **Ringtones SHIP** (un-parked 2026-08-05, 63 tracks live), so `WRITE_SETTINGS` must be an ACTIVE
   line in the manifest — a commented one now breaks Set on every device:
   ```bash
   grep -n "WRITE_SETTINGS" android/app/src/main/AndroidManifest.xml   # must be uncommented
   ```
   It is special-access and shows on the Play listing; the **Data safety form and the listing copy
   must both account for it**, because there is a real feature behind it.
