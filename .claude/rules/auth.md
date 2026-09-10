---
description: Credential Manager sign-in invariants — surface, nonce, copy
paths:
  - "workers/src/routes/auth.ts"
  - "workers/src/lib/jwt.ts"
  - "workers/src/lib/google.ts"
  - "lib/features/auth/**"
  - "lib/core/auth/**"
---

Sign-in is the whole install→login funnel and every failure is silent.

- **Auto-launch a Google surface on the first frame**, never a silent check.
- **At most TWO Google surfaces per attempt**, lost-callback relaunch aside. Sheet first; the BUTTON
  flow follows a sheet that drew nothing, failed, or was DISMISSED. **Never redraw the One Tap
  sheet** — cancels are rate-limited and a 24 h suppression takes automatic sign-in too. No warm-ups.
- **Every ID token carries the per-process nonce; the Worker checks the PAIR**, both absent accepted
  so fielded builds keep working. Never log, toast or track it.
- **ONE retry line for every failure — no fix line, no help link, no language control** (owner's
  call); `classifySignInOutcome` still stamps `login_cancelled`. **Fixed type; the LAYOUT absorbs
  long copy** — title scales, subtitle wraps, pill grows, nothing clips.
- Classify by typed `code` only — a "cancel" sniff swallowed real failures, and `login_cancelled`
  is MIXED: a config error returns `canceled` after a pick. **Every failure return goes through
  `_googleFailure`** or the funnel loses it.
- The stall guard counts CONTINUOUS FOREGROUND time; backgrounding extends it. On RESUME split on
  `SignInPhase.exchanging`: true restarts the full clock, false gets `stallResumeGrace` then abandons
  as `stalled_resumed` — a destroyed selector delivers nothing, ever. A LOST callback relaunches
  ONCE, a dismissal never. `POST /auth/login` retries connectivity failures only, never a RESPONSE.
- `sheetFirst`/`pickerAfterDismiss` stay BUILD consts, never `feature_flags` — `app_config.json`
  is absent on a first launch.

Read [docs/auth.md](../../docs/auth.md) first; cold start
[docs/launch-surface.md](../../docs/launch-surface.md).
