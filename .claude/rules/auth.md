---
description: Credential Manager sign-in invariants — one surface per attempt, nonce, copy
paths:
  - "workers/src/routes/auth.ts"
  - "workers/src/lib/jwt.ts"
  - "workers/src/lib/google.ts"
  - "lib/features/auth/**"
  - "lib/core/auth/**"
---

Sign-in is the whole install→login funnel and every failure is silent: Credential Manager reports a
config error and a dismissal with one code.

- **Auto-launch a Google surface on the first frame**, never a silent check.
- **EXACTLY ONE visible Google surface per attempt.** Sheet first; the picker follows only a sheet
  that drew NOTHING or could not COMPLETE. A DISMISSED sheet stops it — nudge, no picker, no
  automatic retry (the guide forbids it), no warm-ups.
- **Every ID token carries the per-process nonce; the Worker checks the PAIR**, both absent
  accepted so fielded builds keep working. Never log, toast or track it.
- **`login_cancelled` is a MIXED bucket** — a config error returns `canceled` after the user picked
  an account. Split on message text first, timing second; the two spell it differently
  (`description` vs `error`).
- **ONE retry line for every failure — no fix line, no help link** (owner's call);
  `classifySignInOutcome` still stamps `login_cancelled`. **Copy FITS the pill slot at scale 1.0 in
  all six scripts** — shorten, never scale; nothing truncates. No language control on the wall —
  the picker is Settings-only (owner's call).
- Classify by typed `code` only — a "cancel" sniff swallowed real failures. **Every failure return
  goes through `_googleFailure`** or the funnel loses it.
- The stall guard abandons only on CONTINUOUS FOREGROUND time; backgrounding extends it, returning
  restarts it. `POST /auth/login` retries connectivity failures only, in budget; never a RESPONSE.
- `sheetFirst` stays a BUILD const, never a `feature_flags` entry — `app_config.json` is not on disk
  on a first launch.

Read [docs/auth.md](../../docs/auth.md) first; cold start:
[docs/launch-surface.md](../../docs/launch-surface.md).
