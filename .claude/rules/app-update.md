---
description: Play in-app update — never over sign-in, paywall or an apply; silent on failure; beats the review.
paths:
  - "lib/features/app_update/**"
  - "lib/core/update/**"
  - "android/app/src/main/kotlin/**/update/**"
---

- **Never covers** the splash, `/sign-in` (even between attempts), a sign-in attempt, `/premium`,
  or an apply / share / ringtone set still loading. New flows that must not be restarted take an
  `UpdateHolds.hold()`.
- **Never blocks.** A sideload, no Play, offline or any channel error is a silent no-op.
- **FLEXIBLE in progress is not IMMEDIATE in progress** — Play reports both the same way.
- **The update wins the launch** over Play's review sheet via `UpdateHolds.launch`.

Read [docs/app-update.md](../../docs/app-update.md) before changing any of it.
