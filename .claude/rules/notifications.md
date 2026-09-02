---
description: Local reminders only; festival dates are data.
paths:
  - "lib/features/notifications/**"
  - "android/app/src/main/res/raw/**"
---

Local reminders via `flutter_local_notifications` — **no FCM, no Worker, nothing leaves the device,
and no screen may promise a push channel.**

Deliberate decisions that look wrong; do not "fix" them:

- **Festival dates are DATA, not computation.** Lunisolar dates are astronomy no Dart package
  computes to a standard worth putting in front of a devotee. When the table runs out the festival is
  **skipped** — it degrades to "no reminders", never a reminder on a wrong day. Never "fix" it by
  adding 365 days; that puts a lunisolar festival up to a fortnight out. **Nothing warns you when it
  runs out**: the test asserts a fixed floor and never reads the clock, so it keeps passing while
  festivals stop arming.
- **Scheduling is inexact on purpose** — exact alarms are special-access and show on the Play listing.
- QA tools gate on `kDebugMode` **OR** not `isPlayInstall()`. The second half is the point: a
  sideloaded RELEASE build keeps the tools, because every failure worth catching reproduces only in a
  release build.

Traps:

- **`keep.xml` is not optional.** The notification icons are resolved by NAME, R8 strips them, and
  ONLY release builds throw.
- **Festival alarms are one-shot** — the root-widget bootstrap re-arms on every launch, and
  `RECEIVE_BOOT_COMPLETED` plus the boot receiver cover reboots. Lose either and reminders end.
- **The small icon cannot be the launcher icon** — Android keeps only its ALPHA and tints the result,
  so a coloured icon renders as a white square.
- **A channel's sound is immutable once created.** Adding the chime means bumping the channel ids in
  the SAME change and listing the old ones as legacy, or every existing install ignores it.

Read [docs/notifications.md](../../docs/notifications.md).
