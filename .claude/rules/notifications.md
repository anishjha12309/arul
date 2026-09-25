---
description: One channel; campaign pushes come only from the CMS; local posts are one-offs.
paths:
  - "lib/features/notifications/**"
  - "lib/features/push/**"
  - "android/app/src/main/res/raw/**"
---

Campaign pushes come only from the CMS through the Worker. No reminders, no notification setting;
local posts are one-offs on the campaign channel. No screen promises a notification.

Campaign invariants ([docs/push.md](../../docs/push.md)):

- **`arul_updates_v1` is created at LAUNCH, not at opt-in**, and its id is immutable once a device has
  seen it. FCM falls back to the manifest default when the channel does not exist yet, and on
  Android 8–12 the channel IS the user's only control. The NAME is mutable and is localized.
- **The permission prompt fires once per install**, on the first feed frame AFTER sign-in, never on
  the wall or during the Google flow — a stacked dialog costs sign-ins. Denied is final.
- **Notification messages only**, never data-only. **Registering no `onBackgroundMessage` handler is
  what keeps the Flutter isolate out — the plugin's receiver does not check first**, it enqueues its
  background service for every message and the executor then finds no callback handle.
- **Send by `token`, not `fid`.** The REST reference says the opposite; a real device answered 404
  UNREGISTERED to the fid and 200 to the token on an identical payload. `SEND_BY` is the one switch.
- **An unreadable payload opens the app** — unknown `dest`, deleted item, retired category. Never a
  crash, never an error screen. Registration failures are swallowed into Crashlytics.

Traps:

- **`keep.xml` is not optional.** The notification icons are resolved by NAME, R8 strips them, and
  ONLY release builds throw.
- **The plugin re-creates a missing channel when it posts** — retiring a channel means cancelling
  its pending alarms too, never deleting the channel alone.

Read [docs/notifications.md](../../docs/notifications.md).
