# Notifications — the channel, the permission and the local posts

Read before touching `lib/features/notifications/**`. Campaign pushes (FCM, the CMS, taps):
[push.md](push.md). There is no reminder schedule; the one notification setting is the Quick Access bar
([quick-bar.md](quick-bar.md)). No screen promises a notification.

## Two channels, created at launch

`arul_updates_v1` (`defaultImportance`: the local posts, and campaigns on older builds) and
`arul_campaigns_v1` (campaigns, heads-up), both in `NotificationService.initialize()` on EVERY launch —
not at opt-in, for three reasons: FCM falls back to the manifest's `default_notification_channel_id`
when a payload's channel was never created; on Android 8–12 the **channel is** the user's only control;
and a phone upgrading to 13 is pre-granted only if a channel already exists.

**An id is immutable once a device has seen it, its importance only goes down and its sound is fixed at
creation** (NotificationManager reference) — so heads-up took a NEW id. Never delete `arul_updates_v1`:
settings show a count of deleted channels as a spam signal. NAMES are mutable, which is how
`pushChannelNameProvider` localizes both.

**The campaign channel copies the person's choice on `arul_updates_v1`, ONCE**
(`campaignImportanceFor`, stored as `arul_campaign_channel_importance`): blocked → never created, so
campaigns keep posting to the blocked channel; LOW/MIN → created at that level; otherwise HIGH with the
system default sound. Only Dart creates it: `ArulMessagingService` falls back to `arul_updates_v1` and
the manifest default stays there, so a phone that blocked campaigns never gets a fresh, unblocked one. A
custom sound needs audio Arul owns BEFORE the build that first creates the channel.

## Permission — once, after sign-in, on the feed

Asked on the first home-feed frame after a successful sign-in. **Never on the sign-in wall, never during
the Google flow**: a dialog stacked on Credential Manager is the interruption that costs sign-ins.
`arul_push_prompted` is set the moment the OS answers, whatever it answered — Android stops showing the
dialog after two refusals, so a third ask reads back as a fresh refusal.

## Per Android version

| Android | What governs delivery |
| --- | --- |
| 7.0–7.1 (`minSdk`) | No channels: a notification message's `notification_priority` applies; a drawn heads-up campaign needs `PRIORITY_HIGH` AND a sound. No permission. |
| 8.0–12 | The channel governs visibility and the user's mute; `requestPermission()` returns authorized with no dialog. |
| 12+ | **Notification trampolines** are blocked: a tap must be a PendingIntent straight to an activity. Never route one through a BroadcastReceiver or Service. |
| 13+ | Runtime `POST_NOTIFICATIONS`, off by default on a fresh install. The FCM SDK declares it too — the merged manifest must list it ONCE. |
| 14+ | Never set `ongoing` on a campaign or local post (14 lets users dismiss it anyway) — the Quick Access bar is the one ongoing post. A locked Private Space showing nothing (15) is expected. |

Pictures are downloaded and shown by the FCM SDK itself; WebP support "varies", so the CMS stores JPEG
only, and a failed download degrades to text-only. No Google Play services → registration throws, is
caught, and the phone is silently unreachable.

## Deliberate decisions that look wrong — do not "fix"

- **The always-on shortcut bar is a plain ongoing post, never a foreground service** — the policy
  trade-off and its traps are in [quick-bar.md](quick-bar.md).
- **The retired reminders are cleaned up on every launch.** Upgraded phones held
  `arul_devotional_weekly_v1` / `arul_festivals_v1` and native recurring alarms (ids below 3000). The
  plugin RE-CREATES a missing channel when it posts, so deleting the channels alone would grow them back
  on the next alarm: `initialize()` deletes both channels AND cancels every pending id under 3000.
- **Cancel pending by id, never the plugin's `cancelAll`** — that also clears what is on screen, and it
  once wiped unread campaign pushes on every icon launch.
- **The tz database is the `latest_10y` variant** — same zone names, transitions truncated to ±5 years;
  Asia/Kolkata has had one rule since 1945.
- **Scheduling is inexact (`inexactAllowWhileIdle`)** — exact alarms are special-access and show on the
  Play listing; a few minutes' drift is immaterial for a one-off.

## The local posts

- **The unfinished-trial reminder is re-armed by `notificationBootstrap` on every launch from an
  instant PERSISTED at abandonment** — re-arming from "now" would walk it further out on every launch,
  so the people who open the app most would never be reminded. The marker is written when the UPI app
  takes over ([checkout.md](checkout.md)), so it can outlive an approval the app never saw: the re-arm
  asks entitlement (behind the auth seed, never awaited), and ANY premium read retires marker and
  reminder. It **never requests the permission** — a payment failing is not an opt-in; without the
  permission the feed row covers that user.
- **The come-back reminder is for SDK ≤ 32 only, on EVERY install there** — no coin, no kill switch:
  13+ needs `POST_NOTIFICATIONS`, and the wall must never ask. ONE post per install, armed ~60 min after
  the install's FIRST Google surface (`SignInPhase.signals`), disarmed by any settled attempt, any resume
  and any cold start. An arm still awaiting the plugin when a disarm lands cancels what it scheduled
  (`_epoch`). The big picture waits for `/geo` and is a FILE the plugin reads at post time, maybe from
  the boot receiver with no Flutter alive. Android crops a big picture to its CENTRE band — a 9:16
  poster's waist, faces cut off — so the app writes the 2:1 band around `RegionalPoster.faceY`. On a
  13+ test phone: sideload with `QA_COME_BACK_DELAY_S=60` and `pm grant … POST_NOTIFICATIONS`.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification{,_large}` are resolved by NAME
  (`Resources.getIdentifier`) from the plugin, never as `R.*`, so R8 and AGP resource shrinking strip
  them and ONLY release builds throw (`invalid_icon` / `invalid_large_icon`). Check:
  `aapt2 dump resources <release.apk> | grep ic_notification` lists both.
- **One-offs survive a reboot only through `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBootReceiver`**
  — keep both in the manifest.
- **Core library desugaring is required** by the plugin — without it the build fails at AAR metadata
  checking, not at runtime.
- **The small icon cannot be the launcher icon** — Android keeps only its ALPHA and tints it, so a
  coloured icon renders as a white square. The small icon is a white-on-clear gopuram silhouette; the
  gold around it is the accent colour. The coloured mark is the LARGE icon.
- **Android suppresses notifications for the foreground app** — minimise before judging a test send.
  The release-icon check is a CMS "Send to test accounts" campaign to the test phone.
