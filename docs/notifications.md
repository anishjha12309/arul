# Notifications — traps only

Local reminders via `flutter_local_notifications` — **on-device only: no network, no server, nothing
leaves the phone.** Campaign pushes are a SEPARATE feature with separate rules
([push.md](push.md)); the only thing the two share is this class, which creates the campaign channel
at launch because FCM needs it to exist before a message arrives. No screen promises either.

## Deliberate decisions that look wrong — do not "fix"

- Permission is requested **on opt-in only**, never at launch; `syncWithSystem()` flips the toggle
  off if the user revokes it in system settings. Refused twice, Android stops showing its dialog, so
  the toggle deep-links to `ACTION_APP_NOTIFICATION_SETTINGS` — same MainActivity-channel shape as
  Set's `WRITE_SETTINGS`, gated on `shouldShowRequestPermissionRationale` being false after a request
  came back denied. The toggle is NOT parked: granting there costs one more tap on return.
- **Festival dates are DATA, not computation** — lunisolar dates are astronomy no Dart package
  computes to a standard worth putting in front of a devotee. When the table runs out
  `nextOccurrenceAfter` returns null and the festival is **skipped**: it degrades to "no reminders",
  never a reminder on a wrong day. **Never "fix" it by adding 365 days** — that puts a lunisolar
  festival up to a fortnight out.
- Reminders fire `kFestivalLeadDays` ahead and the copy never names a date, so a ±1-day disagreement
  between almanacs is invisible (the Settings "Coming up" card does print it).
- **Scheduling is inexact (`inexactAllowWhileIdle`) on purpose** — exact alarms are special-access
  and show on the Play listing, and a few minutes' drift is immaterial for a weekly or seasonal
  reminder.
- QA tools gate on `qaToolsEnabled` = `kDebugMode` **OR** not `isPlayInstall()` (the same native
  source as FLAG_SECURE, and a loading or errored snapshot resolves to "hide"). The second half is
  the point: a sideloaded RELEASE build keeps the tools, because every failure worth catching
  reproduces only in a release build.

`festivalEvents` is hand-authored and VERIFIED against a published Tamil panchangam. When EXTENDING
coverage, verify the new rows the same way — solar entries follow fixed rules, every
tithi/nakshatra date must be checked. **Nothing warns you when it runs out**: the test asserts a
FIXED calendar floor and never reads the clock, so it keeps passing while festivals stop arming. It
is set a year inside the authored horizon, so it trips before the table runs dry — but a festival
count short of expected in the QA card is the only other signal.

## Traps already paid for

- **`keep.xml` is not optional.** `ic_notification{,_large}` are resolved by NAME
  (`Resources.getIdentifier`) from the plugin, never as `R.*` from Kotlin, so R8 and AGP resource
  shrinking treat them as unused and strip them. ONLY release builds throw — `invalid_icon` for the
  small one, `invalid_large_icon` for the large. Verify:
  `aapt2 dump resources <release.apk> | grep ic_notification` → must list both.
- **Festival alarms are one-shot** — the root-widget watch of `notificationBootstrapProvider` re-arms
  on every launch, and `RECEIVE_BOOT_COMPLETED` plus `ScheduledNotificationBootReceiver` cover
  reboots. Lose either and reminders silently end.
- **Core library desugaring is required** by the plugin — without it the build fails at AAR metadata
  checking, not at runtime.
- **The small icon cannot be the launcher icon** — Android keeps only its ALPHA and tints the result,
  so a coloured icon renders as a white square. The small icon is a white-on-clear gopuram silhouette
  at 24 dp across five density buckets; the gold you see around it is the notification's accent
  colour, not the file. The coloured mark is the LARGE icon, and that one is the launcher art
  recomposed.
- **Android suppresses notifications for the foreground app** — minimise before judging a QA send.
- **`applySettings` cancels EVERY pending notification, including ones these settings do not own.**
  Ids come from list INDEXES, so a reordered or shortened list leaves orphans only `cancelAll`
  reaches. The unfinished-trial reminder is therefore re-armed by `notificationBootstrap` AFTER
  `applySettings`, from an instant persisted at abandonment — re-arming from "now" would walk it
  further out on every launch, so the people who open the app most would be the ones never reminded.
  Anything one-shot added beside it owes the same treatment.
- **The trial reminder NEVER requests the notification permission** — it fires from a payment
  failing, which is not an opt-in. No permission means no reminder; the feed row is what covers that
  user. It rides the EXISTING weekly channel: a channel's sound is immutable once created, and a new
  id would show up as a second toggle in the system settings for one reminder.
- **The master toggle does not own the trial reminder.** It is a follow-up to a payment the user
  started, not a devotional reminder, and `masterEnabled` defaults OFF — gating it there made it
  dead code for the fresh installs that abandon most. Its only gate is the OS permission, which on
  13+ is itself an explicit grant. So the re-arm runs after BOTH bootstrap branches, not inside the
  enabled one.

## Adding the chime

The sound is not in the repo yet (`android/app/src/main/res/raw/` holds only `keep.xml`), and
`_kChimeBundled` is `false` **deliberately**: referencing a raw resource that does not exist makes
the plugin fail channel creation outright, which would take every reminder down, not just its sound.
The device default plays meanwhile.

1. Add `android/app/src/main/res/raw/arul_bell.mp3` — **lower-case, digits and underscores only**,
   AAPT2 fails the build on anything else. A short cut, no leading silence; Android truncates a
   notification sound after a few seconds.
2. Set `_kChimeBundled = true` and, **in the SAME change**, bump both channel ids (`…_v1` → `_v2`)
   and add the old ids to `_legacyChannelIds`. **A channel's sound is immutable once created** —
   without the bump every existing install silently ignores the chime; without the legacy list the
   superseded channels linger in system settings. `keep.xml` already lists `arul_bell` (`tools:keep`
   on a missing resource is a harmless no-op).
