# Notifications — traps only

ONE channel, `arul_updates_v1`, created at launch for campaign pushes ([push.md](push.md)). There is
no reminder schedule and no notification setting. The only LOCAL posts are one-offs the app arms
itself (the unfinished-trial reminder), and they ride that same channel so the system settings list
exactly one Arul channel. No screen promises a notification.

## Deliberate decisions that look wrong — do not "fix"

- **The retired reminders are cleaned up on every launch.** Upgraded phones held
  `arul_devotional_weekly_v1` / `arul_festivals_v1` and native recurring alarms (ids below 3000).
  The plugin RE-CREATES a missing channel when it posts (`createNotification` →
  `setupNotificationChannel`), so deleting the channels alone would grow them back on the next weekly
  alarm: `initialize()` deletes both channels AND cancels every pending id under 3000.
- **Cancel pending by id, never the plugin's `cancelAll`** — that also clears what is on screen, and
  it once wiped unread campaign pushes on every icon launch.
- **The tz database is the `latest_10y` variant, and that is safe here.** Same zone names as `latest`,
  transitions truncated to ±5 years; Asia/Kolkata has had one rule since 1945.
- **Scheduling is inexact (`inexactAllowWhileIdle`) on purpose** — exact alarms are special-access
  and show on the Play listing; a few minutes' drift is immaterial for a one-off.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification{,_large}` are resolved by NAME
  (`Resources.getIdentifier`) from the plugin, never as `R.*` from Kotlin, so R8 and AGP resource
  shrinking treat them as unused and strip them. ONLY release builds throw — `invalid_icon` for the
  small one, `invalid_large_icon` for the large. Verify:
  `aapt2 dump resources <release.apk> | grep ic_notification` → must list both.
- **One-offs survive a reboot only through `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBootReceiver`**
  — keep both in the manifest.
- **Core library desugaring is required** by the plugin — without it the build fails at AAR metadata
  checking, not at runtime.
- **The small icon cannot be the launcher icon** — Android keeps only its ALPHA and tints the result,
  so a coloured icon renders as a white square. The small icon is a white-on-clear gopuram silhouette
  at 24 dp across five density buckets; the gold you see around it is the notification's accent
  colour, not the file. The coloured mark is the LARGE icon, and that one is the launcher art
  recomposed.
- **Android suppresses notifications for the foreground app** — minimise before judging a test
  send. The release-icon check is a CMS `/internal/push/test` send to the test phone.
- **The unfinished-trial reminder is re-armed by `notificationBootstrap` on every launch from an
  instant PERSISTED at abandonment** — re-arming from "now" would walk it further out on every launch,
  so the people who open the app most would never be reminded. The marker is written when the UPI app
  takes over, so it can outlive an approval the app never saw: the re-arm asks entitlement (behind
  the auth seed, never awaited), and ANY premium read retires marker and reminder.
- **The trial reminder NEVER requests the notification permission** — it fires from a payment
  failing, which is not an opt-in. No permission means no reminder; the feed row covers that user.
- **The come-back reminder is Android 12L and below only** (SDK ≤ 32), for EVERY install on that
  tier — no coin, no kill switch: 13+ needs `POST_NOTIFICATIONS`, and the wall must never ask. ONE
  post per install, armed ~60 min after the install's FIRST Google surface (`SignInPhase.signals`),
  disarmed by any settled attempt, any resume and any cold start. An arm still awaiting the plugin
  when a disarm lands cancels what it scheduled (`_epoch`). The big picture waits for `/geo` (the
  first surface lands before it) and
  is a FILE the plugin reads at post time, maybe from the boot receiver with no Flutter alive.
  Android crops a big picture to its CENTRE band — a 9:16 poster's waist, faces cut off, seen on
  device — so the app writes the 2:1 band around `RegionalPoster.faceY`. On a 13+ test phone:
  sideload with `QA_COME_BACK_DELAY_S=60` and `pm grant … POST_NOTIFICATIONS`.
