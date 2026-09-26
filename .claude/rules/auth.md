---
description: Credential Manager sign-in invariants — surface, nonce, copy
paths:
  - "workers/src/routes/auth.ts"
  - "workers/src/lib/jwt.ts"
  - "workers/src/lib/google.ts"
  - "lib/features/auth/**"
  - "lib/core/auth/**"
---

- **Auto-launch a Google surface on the first frame**, never a silent check.
- **At most TWO Google surfaces per attempt**: sheet first, the BUTTON flow after a sheet that
  drew nothing, failed or was DISMISSED. **Never redraw the One Tap sheet** —
  a 24 h cancel suppression takes automatic sign-in too. No warm-ups.
- **Every ID token carries the per-process nonce; the Worker checks the PAIR** (both absent accepted
  for fielded builds). Never log, toast or track it.
- **ONE retry line for every failure; no fix line, no help link. The pill is the wall's ONLY
  tappable thing**. Region picks the language, Settings changes it.
  Fixed type; the LAYOUT absorbs copy.
- Classify by typed `code` only; `login_cancelled` is MIXED. **Every failure return goes through
  `_googleFailure`.**
- The stall guard counts FOREGROUND time and reads the lifecycle every 250 ms. On RESUME,
  `exchanging` restarts the clock, else `stallResumeGrace` then `stalled_resumed`. A LOST callback
  relaunches ONCE, a dismissal never — bar `selectorStripped` and `addAccountAbandoned` (the
  PICKER once, never the sheet). `POST /auth/login` retries connectivity failures only.
- `noPlayServices` shows GOOGLE'S update dialog (`PlayServicesChannel`), never our copy.
- **A RETURN re-arms the automatic sheet ONCE** (`noteAppLifecycle`; `inactive` is not away), and
  a RECONNECT (`noteConnectivity`): offline→online, network failure or GMS's `[16] reauth`
  cancel, RESUMED, 2/stretch, never a user cancel. No network at launch HOLDS it (a known `none`
  only) until link-up or any resume; the pill stays live.
- `sheetFirst`/`pickerAfterDismiss` stay BUILD consts — no `app_config.json` on first launch.

Read [docs/auth.md](../../docs/auth.md) first; cold start
[launch-surface.md](../../docs/launch-surface.md).
