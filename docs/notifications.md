# Notifications

Read this when changing devotional reminders, adding the chime, or extending the festival calendar.
Behaviour contracts live in [edge-cases.md](edge-cases.md) §Notifications.

Local only — `flutter_local_notifications`, no FCM, no Worker, nothing leaves the device. There is no
push channel, so no screen may promise one (the upload confirmation deliberately does not).

## Contracts

- Permission is requested **on opt-in only**, never at launch. ON persists only when Android actually
  granted it, and `syncWithSystem()` flips it back off if the user later revokes it in system settings.
- Festival dates are DATA, not computation. Table runs out → that festival is **skipped**, never
  extrapolated (`nextOccurrenceAfter` returns null). See below.
- Reminders fire 3 days AHEAD and never name a date, so a ±1-day panchangam disagreement is invisible.
- `notificationBootstrapProvider` is watched from the ROOT widget: festival alarms are one-shot, so the
  launch-time re-arm is what carries the schedule past each festival into the next.
- `RECEIVE_BOOT_COMPLETED` + `ScheduledNotificationBootReceiver` — without them one reboot silently ends
  every pending reminder until the app is next opened.
- A channel's sound is immutable once created; adding the chime means bumping the channel id AND listing
  the old one in `_legacyChannelIds`.

## Shape

| | |
| --- | --- |
| Weekly | One, Friday — Velli Kizhamai. Native recurrence (`dayOfWeekAndTime`); armed once, repeats forever |
| Festivals | ~16/year, fired 3 days ahead. One-shot alarms, re-armed on every launch |
| Volume | ~2/month, matching Pakiza's weekly + 8 annual |
| Controls | One master toggle + one reminder time (default 08:00). No per-festival opt-ins |
| Tap | Payload = the category slug → selects it, then routes `/browse` |

Adding a weekly day (Mon Sivan / Tue Murugan / Sat Perumal) is a one-entry change in
`weeklyDevotionalDays`. Weigh it against the volume line above first.

## The festival table needs verifying

`festivalEvents` in `domain/devotional_event.dart` is **hand-authored and UNVERIFIED**. Hindu festivals
are lunisolar — the date depends on the tithi or nakshatra at sunrise, which is astronomy, and no Dart
package computes it to a standard worth putting in front of a devotee. So they are data.

**Check every tithi/nakshatra date against a published Tamil panchangam before the Play release.**
The solar entries (Pongal, Makaravilakku, Puthandu, Aadi Perukku) follow fixed rules and are dependable;
everything else is a best effort. The list is laid out one date per line precisely so it can be
eyeballed — it is a ~20-minute job.

Two design choices contain the damage until then, and both must be preserved:

- Reminders fire `kFestivalLeadDays` (3) ahead and **never name a date**, so a ±1-day disagreement
  between almanacs is invisible.
- `nextOccurrenceAfter` returns **null** when a festival's dates run out, and the scheduler skips it.
  An expired table degrades to "no reminders", never to a reminder on a wrong day. Never "fix" this by
  adding 365 days — that puts a lunisolar festival up to a fortnight out.

Coverage runs to end-2031; `test/features/notifications/devotional_event_test.dart` fails from 2030 so
the refresh is a chore, not an outage.

## Testing on device

Settings → Reminders carries a **TESTING** card with three checks. It is present in debug **and in a
sideloaded release APK**, and absent from the Play build — gated on `qaToolsEnabled`
(`core/config/build_info.dart`), which asks the native `isPlayInstall()` that FLAG_SECURE already uses,
so the two can never disagree. It is deliberately **not** `kDebugMode`: every failure worth catching here
happens only in a release build, so a debug-only gate would hide the tools in exactly the build that
breaks.

| Check | Answers |
| --- | --- |
| Send a test notification | Does anything reach the shade at all — permission, channel, OEM battery policy |
| Preview every reminder | Do the real icons, copy, accent and sound render? Fires the PRODUCTION notifications, so it is what catches R8 having stripped `ic_notification` |
| What's armed right now | Did the alarms actually schedule? Reads the OS's pending set and reports `weekly/expected · festivals/expected`, plus any festival skipped for want of a future date |

**Minimise the app after tapping** — Android suppresses notifications for the app in the foreground.

A festival count short of expected is not a defect: it is the table having run out for that festival,
which is otherwise completely silent. That is the number to watch as 2031 approaches.

Verify the release APK actually kept the icons:

```bash
aapt2 dump resources build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | grep ic_notification
# must list BOTH drawable/ic_notification and drawable/ic_notification_large
```

## Adding the chime

The reminders are wired for a custom sound that is not in the repo. Until it lands they use the device's
default tone; everything else is complete.

1. Add the audio as **`android/app/src/main/res/raw/arul_bell.mp3`** — lower-case, digits and
   underscores only. AAPT2 fails the build on anything else (an uppercase filename is why this note is
   here and not in `res/raw/`).
2. Set `_kChimeBundled = true` in `data/notification_service.dart`.
3. **Bump both channel ids** `arul_devotional_weekly_v1` → `_v2` and `arul_festivals_v1` → `_v2`, and add
   the old ids to `_legacyChannelIds`. A channel's sound is immutable once created on a device, so
   without the bump the new chime is silently ignored by every existing install — and without the
   legacy list the superseded channels linger as duplicates in system settings.

Steps 2 and 3 are ONE change. `keep.xml` already lists `arul_bell`; `tools:keep` on a missing resource
is a harmless no-op, so it needs no edit.

### Format

1–3 s, 44.1 kHz, mp3 (ogg also decodes). Normalise to about −16 LUFS with ~1 dB headroom, and no leading
silence. Android truncates a notification sound at ~5 s, and a long clip reads as an alarm rather than a
reminder. A temple bell, a conch or a short udukkai phrase all fit; it has to be recognisable at phone-
speaker volume.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification` and `ic_notification_large` are resolved by NAME at
  runtime, so R8 resource shrinking strips them and release builds throw `invalid_icon` while debug is
  fine.
- **Core library desugaring is required** by the plugin (`isCoreLibraryDesugaringEnabled` +
  `desugar_jdk_libs`). Without it the build fails at `checkDebugAarMetadata`, not at runtime.
- **The small icon cannot be the launcher icon.** Android flattens and tints it — a coloured icon renders
  as a white square. `ic_notification.xml` is a monochrome gopuram silhouette; the coloured mark is the
  separate large icon.
- **Scheduling is inexact** (`inexactAllowWhileIdle`) on purpose: exact alarms are special-access and
  would show on the Play listing. A few minutes' drift is immaterial for weekly and seasonal reminders.
