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
     survives in `MainActivity.kt`; one that only exists inside a comment does not count.
   - `release-commit-reminder.js` reminds you to commit after a successful release build left
     source uncommitted (an artifact is only reproducible if its source is in git).

   All three match the command pattern anywhere in a string, so avoid echoing "flutter build
   appbundle" literally in an unrelated command.
1. Build: `flutter build appbundle --release --dart-define-from-file=env/prod.json`
   (APK for sideload testing: `flutter build apk --release ...`).
2. Signing preconditions: `android/key.properties` + keystore `C:\Users\anish\arul-upload.jks`
   (alias `arul`; passwords in the user's password manager — never ask to paste them into chat).
   **Missing key.properties silently falls back to DEBUG signing** — always verify:
   ```bash
   jarsigner -verify -certs -verbose build/app/outputs/bundle/release/app-release.aab | grep "CN="
   ```
   Must show `CN=HSR Apps`. `CN=Android Debug` = NOT release-signed; stop.
3. Sanity: check dart-defines took effect via `aapt dump badging` on an APK if in doubt.
4. Play upload = user task (Play App Signing ON). **v1.0.0+20 is already uploaded** (not public yet).
   SHA-1/256 registration — BOTH the app-signing and upload certs (Play Console → Setup → App
   signing) in the Google Cloud OAuth Android client + Firebase — is required after the first
   upload, or Google Sign-In is broken for testers. That state lives in Play Console, so confirm it
   there; re-check only if the upload key rotates. No rebuild needed either way.
5. Before the app goes PUBLIC (docs/provisioning.md): privacy policy live ✓
   (`https://hsrapps.com/arul/privacy-policy/`), PhonePe PROD webhook registered ✓, real analytics
   creds in env/prod.json ✓, FLAG_SECURE ✓ (Play-install-gated, guard-enforced — v1.0.0+20 shipped
   without it, so the first public build must be newer).
6. **Ringtones ship PARKED** — the tab has no route and `WRITE_SETTINGS` is out of the manifest, on
   purpose (docs/known-issues.md). A release whose `aapt2 dump permissions` still lists
   `WRITE_SETTINGS` means the parking regressed. Do not "restore" it to fix a build.
