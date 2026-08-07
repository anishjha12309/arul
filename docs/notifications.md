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
- Reminders fire `kFestivalLeadDays` (3) ahead and never name a date, so a ±1-day disagreement
  between almanacs is invisible.
- **Scheduling is inexact** (`inexactAllowWhileIdle`) on purpose: exact alarms are special-access and
  show on the Play listing.
- QA tools gate on `qaToolsEnabled` → native `isPlayInstall()` (same source as FLAG_SECURE),
  deliberately NOT `kDebugMode` — every failure worth catching reproduces only in a release build.

`festivalEvents` (`domain/devotional_event.dart`) is **hand-authored and UNVERIFIED** — check
tithi/nakshatra dates against a published Tamil panchangam before the Play release (solar entries are
dependable). Coverage to end-2031; `devotional_event_test.dart` fails from 2030 so the refresh is a
chore, not an outage. A festival count short of expected in the QA card = the table ran out, silent
otherwise.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification{,_large}` are resolved by NAME, R8 strips them, and
  ONLY release builds throw `invalid_icon`. Verify:
  `aapt2 dump resources <release.apk> | grep ic_notification` → must list both.
- **Festival alarms are one-shot** — the root-widget watch of `notificationBootstrapProvider` re-arms
  on every launch, and `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBootReceiver` cover reboots;
  lose either and reminders silently end.
- **Core library desugaring is required** by the plugin — without it the build fails at
  `checkDebugAarMetadata`, not at runtime.
- **The small icon cannot be the launcher icon** — Android flattens and tints it to a white square;
  `ic_notification.xml` is a monochrome gopuram, the coloured mark is the large icon.
- **Android suppresses notifications for the foreground app** — minimise before judging a QA send.

## Adding the chime (sound not yet in repo; device default plays meanwhile)

1. `android/app/src/main/res/raw/arul_bell.mp3` — **lower-case/digits/underscores only**, AAPT2 fails
   the build on anything else. 1–3 s, no leading silence, ~−16 LUFS (Android truncates at ~5 s).
2. Set `_kChimeBundled = true` in `data/notification_service.dart` and, in the SAME change, bump both
   channel ids (`…_v1` → `_v2`) and add the old ids to `_legacyChannelIds`. **A channel's sound is
   immutable once created** — without the bump every existing install silently ignores the chime;
   without the legacy list the superseded channels linger in system settings. `keep.xml` already
   lists `arul_bell` (`tools:keep` on a missing resource is a harmless no-op).
