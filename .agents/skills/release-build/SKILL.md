---
name: release-build
description: Build and verify the signed Arul release AAB/APK for Play. Use for release builds, signing checks, or Play-upload prep.
---

# Release Build

0. **Version-bump guard (hook):** a PreToolUse hook (`.Codex/hooks/release-version-guard.js`)
   BLOCKS any release build whose pubspec version was already built from different source
   (state: git-ignored `.Codex/last-release-build.json`). If blocked: bump `version:` in
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
4. Play upload = user task (Play App Signing ON). After first upload: register BOTH app-signing and
   upload SHA-1/256 (Play Console → Setup → App signing) in the Google Cloud OAuth Android client +
   Firebase — **Google Sign-In is broken for testers until then.** No rebuild needed.
5. Pre-launch gate (docs/provisioning.md): privacy policy live, PhonePe prod webhook registered,
   real analytics creds in env/prod.json, **FLAG_SECURE added** (docs/edge-cases.md).
