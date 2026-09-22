---
description: Local reminders are on-device; campaign pushes come only from the CMS.
paths:
  - "lib/features/notifications/**"
  - "lib/features/push/**"
  - "android/app/src/main/res/raw/**"
---

TWO features, one plugin. **Reminders** are on-device. **Campaign pushes** come only from the CMS
through the Worker, never from the app. No screen promises either.

Campaign invariants ([docs/push.md](../../docs/push.md)):

- **`arul_updates_v1` is created at LAUNCH, not at opt-in**, and its id is immutable once a device has
  seen it. FCM falls back to the manifest default when the channel does not exist yet, and on
  Android 8–12 the channel IS the user's only control. The NAME is mutable and is localized.
- **The permission prompt fires once per install**, on the first feed frame AFTER sign-in, never on
  the wall or during the Google flow — a stacked dialog costs sign-ins. Denied is final. The
  after-sign-in paywall side asks when `/premium` closes, never over it.
- **Notification messages only**, never data-only. **Registering no `onBackgroundMessage` handler is
  what keeps the Flutter isolate out — the plugin's receiver does not check first**, it enqueues its
  background service for every message and the executor then finds no callback handle. Register one
  anywhere and that gate opens for every message, on phones whose battery manager kills isolates.
- **Send by `token`, not `fid`.** The REST reference says the opposite; a real device answered 404
  UNREGISTERED to the fid and 200 to the token on an identical payload. `SEND_BY` is the one switch.
- **An unreadable payload opens the app** — unknown `dest`, deleted item, retired category. Never a
  crash, never an error screen. Registration failures are swallowed into Crashlytics.

Reminder decisions that look wrong; do not "fix" them:

- **Festival dates are DATA, not computation** — lunisolar dates are astronomy no Dart package
  computes well enough to put in front of a devotee. When the table runs out the festival is
  **skipped**, never fired on a wrong day; never "fix" it by adding 365 days. **Nothing warns you
  when it runs out**: the test asserts a fixed floor and never reads the clock.

Traps:

- **`keep.xml` is not optional.** The notification icons are resolved by NAME, R8 strips them, and
  ONLY release builds throw.
- **Festival alarms are one-shot** — the root-widget bootstrap re-arms every launch, the boot receiver
  covers reboots. Lose either and reminders end.
- **A channel's sound is immutable once created.** Adding the chime means bumping the reminder channel
  ids in the SAME change and listing the old ones as legacy.

Read [docs/notifications.md](../../docs/notifications.md).
