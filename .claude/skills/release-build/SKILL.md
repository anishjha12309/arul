---
name: release-build
description: Build and verify the signed Arul release AAB/APK for Play. Use for release builds, signing checks, or Play-upload prep.
---

# Release Build

0. **Version-bump guard (hook):** a PreToolUse hook (`.claude/hooks/release-version-guard.js`)
   BLOCKS any release build whose pubspec version was already built from different source
   (state: git-ignored `.claude/last-release-build.json`). If blocked: bump `version:` in
   pubspec.yaml (+1 build number) and retry. AAB then APK back-to-back from identical source
   shares one version — allowed by design. The guard matches the pattern anywhere in a command
   string, so avoid echoing "flutter build apk" literally.
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
   creds in env/prod.json ✓ — **FLAG_SECURE is the one still open** (docs/edge-cases.md).
   v1.0.0+20 shipped without it.
