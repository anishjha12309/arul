---
description: Two channels; campaign pushes come only from the CMS; local posts are one-offs.
paths:
  - "lib/features/notifications/**"
  - "lib/features/push/**"
  - "android/app/src/main/res/raw/**"
  - "android/**/push/**"
  - "lib/features/quick_bar/**"
  - "android/**/quickbar/**"
  - "android/app/src/main/res/layout/quick_bar_*"
---

Campaign pushes come only from the CMS through the Worker. No reminders; local posts are one-offs on
`arul_updates_v1`. No screen promises a notification. The one setting and the one ongoing post is the
Quick Access bar — a plain post, never a foreground service ([docs/quick-bar.md](../../docs/quick-bar.md)).

Campaign invariants ([docs/push.md](../../docs/push.md)):

- **Both channels are created at LAUNCH, not at opt-in**, and an id is immutable once a device has
  seen it. FCM falls back to the manifest default when the channel does not exist yet, and on
  Android 8–12 the channel IS the user's only control. NAMES are mutable and are localized.
- **`arul_campaigns_v2` (the bell) is created by Dart only, once, at the person's level on v1, else
  on `arul_updates_v1`** — blocked stays blocked (v1 kept). Never natively, never raised.
- **The permission prompt fires once per install**, on the first feed frame AFTER sign-in, never on
  the wall or during the Google flow — a stacked dialog costs sign-ins. Denied is final.
- **Data-only campaigns are drawn natively** (`ArulMessagingService`), never in Dart. **Registering no
  `onBackgroundMessage` handler is what keeps the Flutter isolate out — the plugin's receiver does not
  check first**: it enqueues its background service for every message and finds no callback handle.
- **Send by `token`, not `fid`.** The REST reference says the opposite; a real device answered 404
  UNREGISTERED to the fid and 200 to the token on an identical payload. `SEND_BY` is the one switch.
- **An unreadable payload opens the app** — unknown `dest`, deleted item, retired category. Never a
  crash, never an error screen. Registration failures are swallowed into Crashlytics.

Traps:

- **`keep.xml` is not optional.** The notification icons and `raw/arul_bell` are resolved by NAME, R8
  strips them, and ONLY release builds break (a stripped bell leaves the channel silent for good).
- **The plugin re-creates a missing channel when it posts** — retiring a channel means cancelling
  its pending alarms too, never deleting the channel alone.

Read [docs/notifications.md](../../docs/notifications.md).
