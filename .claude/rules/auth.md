---
description: Credential Manager sign-in invariants — one surface per attempt, and the nonce.
paths:
  - "workers/src/routes/auth.ts"
  - "workers/src/lib/jwt.ts"
  - "workers/src/lib/google.ts"
  - "lib/features/auth/**"
  - "lib/core/auth/**"
---

Sign-in is the whole install→login funnel and every failure here is silent: Credential Manager
reports a configuration error and a user dismissal with the same code.

- **Auto-launch a Google surface on the first frame** — never a silent, no-UI check.
- **EXACTLY ONE visible Google surface per attempt.** Sheet first; the picker follows only when the
  sheet drew NOTHING or could not COMPLETE. A DISMISSED sheet stops the attempt — nudge, no picker,
  never an automatic retry, which the Credential Manager guide forbids. Warm-ups stay forbidden.
- **Every ID token carries the per-process nonce and the Worker checks the PAIR**, with both absent
  accepted so fielded builds keep signing in. Never log, toast or track the value.
- **`login_cancelled` is a MIXED bucket** — a config error returns `canceled` after the user already
  picked an account. Split on the message text first, timing second, and note the two events spell it
  differently: `login_cancelled` carries `description`, `login_failed` carries `error`.
- Classify by typed `code` only — a string-sniff for "cancel" swallowed real failures. **Every
  failure return goes through `_googleFailure`**, or the funnel loses the event.
- The stall guard abandons only on CONTINUOUS FOREGROUND time; backgrounding extends it and returning
  restarts the clock. `POST /auth/login` retries connectivity-class failures only, inside that
  budget; a server RESPONSE is never retried.
- The `sheetFirst` kill switch stays a BUILD const, never a `feature_flags` entry — `app_config.json`
  is not on disk on a first launch.

Read [docs/auth.md](../../docs/auth.md) before changing any of it; cold-start ordering is in
[docs/launch-surface.md](../../docs/launch-surface.md).
