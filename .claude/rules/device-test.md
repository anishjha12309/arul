---
description: On-device Maestro rig — identifiers, forbidden adb, what it may not tap.
paths:
  - "tools/device-test/**"
---

- **Maestro sees SEMANTICS, never `Key`s** — a Flutter key never reaches the accessibility layer.
  Address controls by `Semantics(identifier:)`; a fresh wrapper needs `container: true` or the node
  can be merged away. Every id is listed in `tools/device-test/README.md` — **renaming one is a
  breaking change to the rig**, so move the table in the same edit.
- **Nothing may tap `arul_paywall_cta`.** A tap starts a real PhonePe mandate against a real UPI app
  on the owner's phone. Assert it visible; never press it.
- **Never `pm clear`** (it signs the phone out and burns a fresh-install funnel event) and **never
  `adb install -d`** (phones carry versionCode 20xx; a flat debug APK must be allowed to fail).
- **`run.ps1` is ASCII-only and BOM-less.** Windows PowerShell 5.1 decodes a BOM-less file as ANSI,
  so a UTF-8 em dash terminates a string and the script stops parsing. No `&&`, no ternary, no `??`.
- **The wallpaper is left as applied; the owner sets it back.** Record and print it, never restore
  and never prompt. Everything else IS replayed: ringtone rows, `POST_NOTIFICATIONS`, the
  `WRITE_SETTINGS` appop, airplane mode.
- **OEM and GMS surfaces are `env` parameters, never literals**: the account email, the live-chooser
  confirm, the permission dialog's allow/deny wording. Pass a value; do not edit a flow.
- `preview_focus.yaml` deliberately ends with audio PLAYING — `dumpsys audio` is only readable while
  focus is held. `preview_stop.yaml` is the other half; never ship one without the other.
- `maestro check-syntax` runs per FILE, not per directory, and `run.ps1 -NoDevice` does the sweep.
