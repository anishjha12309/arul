# Notifications — traps only

Local reminders via `flutter_local_notifications` — no FCM, no Worker, nothing leaves the device, and
no screen may promise a push channel. Contracts: [edge-cases.md](edge-cases.md) §Notifications.

## Deliberate decisions that look wrong — do not "fix"

- Permission is requested **on opt-in only**, never at launch; `syncWithSystem()` flips the toggle off
  if the user revokes in system settings.
- **Festival dates are DATA, not computation** — lunisolar dates are astronomy no Dart package
  computes to a standard worth putting in front of a devotee. Table runs out → `nextOccurrenceAfter`
  returns null and the festival is **skipped**: degrades to "no reminders", never a reminder on a
  wrong day. Never "fix" by adding 365 days — that puts a lunisolar festival up to a fortnight out.
- Reminders fire `kFestivalLeadDays` (3) ahead and the reminder copy never names a date, so a ±1-day
  disagreement between almanacs is invisible (the Settings "Coming up" card does print it).
- **Scheduling is inexact** (`inexactAllowWhileIdle`) on purpose: exact alarms are special-access and
  show on the Play listing.
- QA tools gate on `qaToolsEnabled` = `kDebugMode` **OR** not `isPlayInstall()` (same native source as
  FLAG_SECURE). The second half is the point: a sideloaded RELEASE build keeps the tools, because every
  failure worth catching reproduces only in a release build.

`festivalEvents` (`domain/devotional_event.dart`) is hand-authored and VERIFIED against a published
Tamil panchangam. When EXTENDING coverage, verify the new rows the same way — solar entries follow
fixed rules, every tithi/nakshatra date must be checked. **Nothing warns you when it runs out**:
`devotional_event_test.dart` asserts a fixed floor (every festival authored past 2030-01-01) and never
reads the clock, so it keeps passing while festivals stop arming. A festival count short of expected
in the QA card is the only signal; it is silent otherwise.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification{,_large}` are resolved by NAME, R8 strips them, and
  ONLY release builds throw — `invalid_icon` for the small one, `invalid_large_icon` for the large.
  Verify:
  `aapt2 dump resources <release.apk> | grep ic_notification` → must list both.
- **Festival alarms are one-shot** — the root-widget watch of `notificationBootstrapProvider` re-arms
  on every launch, and `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBootReceiver` cover reboots;
  lose either and reminders silently end.
- **Core library desugaring is required** by the plugin — without it the build fails at
  `checkDebugAarMetadata`, not at runtime.
- **The small icon cannot be the launcher icon** — Android keeps only its ALPHA and tints the result,
  so a coloured icon renders as a white square. `drawable-*/ic_notification.png` is a white-on-clear
  gopuram silhouette (5 buckets, 24dp); the gold you see around it is `_accent` on the notification,
  not the file. The coloured mark is the LARGE icon, and that one IS the launcher art.
- **Android suppresses notifications for the foreground app** — minimise before judging a QA send.

## Adding the chime (sound not yet in repo; device default plays meanwhile)

1. `android/app/src/main/res/raw/arul_bell.mp3` — **lower-case/digits/underscores only**, AAPT2 fails
   the build on anything else. 1–3 s, no leading silence, ~−16 LUFS (Android truncates at ~5 s).
2. Set `_kChimeBundled = true` in `data/notification_service.dart` and, in the SAME change, bump both
   channel ids (`…_v1` → `_v2`) and add the old ids to `_legacyChannelIds`. **A channel's sound is
   immutable once created** — without the bump every existing install silently ignores the chime;
   without the legacy list the superseded channels linger in system settings. `keep.xml` already
   lists `arul_bell` (`tools:keep` on a missing resource is a harmless no-op).
