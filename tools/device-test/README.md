# Device test rig — Maestro flows + adb assertions

A release-build regression pass in one command. Maestro drives the UI through the SEMANTICS tree;
`run.ps1` owns everything Maestro cannot see — the wallpaper the OS holds, the ringtone rows, the
audio focus stack, armed alarms, the crash buffer, `FeedVideo` re-opens, bytes per card.

The matrix it encodes is [`docs/edge-cases.md`](../../docs/edge-cases.md). Anything in that index
that a script cannot judge is listed under **Not automatable** below and stays the owner's walk.

## Run

```powershell
flutter build apk --release --split-per-abi --dart-define-from-file=env/prod.json
tools\device-test\run.ps1 `
  -Apk build\app\outputs\flutter-apk\app-arm64-v8a-release.apk `
  -Free free@example.com -Premium premium@example.com
```

`-SkipInstall` tests what is on the phone. `-NoDevice` syntax-checks the flows and exits — use it
before touching a phone. `-Serial` picks a device; `-MaestroBin` points at `maestro.bat`.

**Preconditions the rig will not create for you.** Both Google accounts must already be on the
phone; the rig never adds one. The phone must already be signed in to Arul as *some* account — the
first sign-in on a fresh install is a funnel event, not a fixture. Wi-Fi on. Screen unlocked and
staying awake (`adb shell settings put global stay_on_while_plugged_in 3`).

Install: Maestro CLI 2.x from the GitHub release zip (Windows has no installer script), extracted
anywhere, with `maestro\bin` on `PATH`; Java 17+ on `JAVA_HOME`. `maestro --version` must answer.

## Order of the pass

FREE → `signout_signin` · `launch` · `feed_browse` · `paywall_free` · `preview_focus` +
`preview_stop` · `policy_offline` · `reminders_permission` · `process_death`.
PREMIUM → `signout_signin` · `apply_static` · `apply_live` · `set_ringtone` · `share`.
Then `signout_signin` back to FREE, so the phone is left where it started.

`preview_focus` **deliberately ends with audio playing** — `dumpsys audio` can only be read while
focus is held. `preview_stop` is the other half; never run the first alone.

## Semantic identifiers

Maestro cannot see Flutter `Key`s — they never reach the accessibility layer. Only
`Semantics(identifier:)` does, and it is announced to nobody, so an id is free at the UI layer and
survives all six locales. **Text selectors are the fallback, not the default:** every visible string
here is an ARB key except the dock labels (forced English), the apply sheet and the paywall.

| id | where |
| --- | --- |
| `arul_tab_wallpapers` `arul_tab_ringtones` `arul_tab_settings` | dock; derived from the glyph enum, not the label |
| `arul_signin_pill` `arul_signin_subtitle` `arul_signin_language` | the wall — subtitle carries its own text as its label |
| `arul_chip_<slug>` | every browse chip on both tabs, and the upload category row |
| `arul_feed_apply` `arul_feed_share` `arul_feed_retry` `arul_feed_browse_all` | feed card actions and its two state views |
| `arul_live_mark` | the ONLY thing separating a live card from a static one |
| `arul_apply_home` `arul_apply_lock` `arul_apply_both` `arul_apply_confirm` | static apply sheet; the target cards carry `selected` |
| `arul_ringtone_preview` `arul_ringtone_set` | one per row — always select with `index: 0` |
| `arul_settings_premium` `_refer` `_tell_friend` `_reminders` `_language` `_theme` `_help` `_upload` | the rows card |
| `arul_settings_logout` `arul_settings_delete` | below it |
| `arul_confirm_ok` `arul_confirm_cancel` | the confirm dialog, shared by sign-out and delete |
| `arul_policy_privacy` `arul_policy_terms` `arul_policy_refund` `arul_policy_retry` | footer links and the reader's offline Retry |
| `arul_reminders_toggle` | the master switch; read it with `checked:` |
| `arul_paywall_cta` `arul_paywall_upi_chip` `arul_upi_option_<i>` | paywall footer and the picker sheet |
| `arul_upload_pick` `arul_upload_kind_wallpaper` `arul_upload_kind_ringtone` `arul_upload_submit` | upload |

Adding one: put it on the Semantics node that already exists (`ArulButton`, `CtaButton` and friends
take an `identifier`), or wrap with `Semantics(container: true, identifier: …)` — `container: true`
is what guarantees the node survives into the Android tree. Never `excludeSemantics` on a row whose
children carry text a screen reader needs. Then add the row above.

## What the wrapper asserts, and why the flow cannot

- **`dumpsys wallpaper`** — `mWallpaperId` bumps on a static commit; the live check is the component
  becoming ours. A live apply ALWAYS opens the system chooser and the notifier finishes IDLE, so the
  app never claims success and the flow has nothing to assert.
- **`settings get system ringtone`** and every OEM row matching `*ringtone*` — one Set writes ONE
  tone to EVERY SIM row; the row COUNT must not move either.
- **`dumpsys audio`** — `GAIN_TRANSIENT` while previewing, nothing at all after. A leaked permanent
  gain kills the user's music for the rest of the session and is invisible on screen.
- **`dumpsys alarm`** — the reminder flow turns the toggle on and off again; alarms must not survive.
- **`logcat -b crash`** — cleared at the start of the pass, so a hit belongs to this run.
- **`FeedVideo: … re-open`** — the pool must reuse players, never dispose and recreate. Non-zero is
  the regression whatever the screen looked like.
- **`wlan0` rx bytes ÷ 8 cards** — a browse must cost the cards reached, not the cards beyond.

## Traps

- **The wallpaper is left as applied; the owner sets it back.** The before-state is recorded and
  printed as `INFO` — never restored, never prompted for. Everything else — ringtone rows,
  `POST_NOTIFICATIONS`, the `WRITE_SETTINGS` appop, airplane mode — is recorded and replayed.
- **Never `pm clear`.** It signs the phone out and burns a fresh-install funnel event.
- **Never `adb install -d`.** Phones carry versionCode 20xx; a flat debug APK is refused as a
  downgrade, and `-d` forces through exactly the mistake worth seeing.
- **Never `flutter test` while `flutter build` runs** — they fight over the same build directory.
- **Release builds need an accessibility service before `uiautomator dump` returns anything.**
  Maestro brings its own driver APK and does not, which is the whole reason it is here; if you fall
  back to raw `adb shell uiautomator`, turn one on first.
- **`run.ps1` is ASCII-only on purpose.** It is BOM-less, and Windows PowerShell 5.1 decodes a
  BOM-less file as ANSI — a UTF-8 em dash then terminates a string and the script will not parse.
- **Nothing may tap the paywall's buy button.** `arul_paywall_cta` is asserted visible and never
  tapped: a tap starts a real PhonePe mandate against a real UPI app on the owner's phone.
- **The Google account picker is GMS UI, not ours.** It is matched by the account EMAIL passed as
  `ACCOUNT_EMAIL`. "Add another account" is a hard fail, correctly.
- **The live-wallpaper chooser and the OS permission dialogs are OEM text.** They are flow `env`
  parameters (`LIVE_CHOOSER_CONFIRM`, `DENY_LABEL`, `ALLOW_LABEL`) with AOSP defaults — pass a new
  value, never edit the flow.
- **The UPI picker only opens with two or more mandate-capable apps installed.** With one, the chip
  has no tap target by design, so those assertions are conditional. "PhonePe is selected AND first"
  is proven as: the paywall footer names PhonePe (the only place that string appears), and row 0 of
  the picker carries `selected`.

## Not automatable — the owner's walk

- **Payment.** Every mandate is real money and a real UPI app. The rig stops at the paywall.
- **Real slow network.** Airplane mode is binary; the failures that matter (a 3G stall mid-download,
  a token mint dying on LTE) need a shaped link and a stopwatch.
- **Frame-freeze and jank judgement.** `gfxinfo` reads 0 under Flutter and an idle screen scores 70%
  "janky"; whether a fling felt smooth is an eye, not a counter.
- **Share content.** EXACTLY ONE link leaves per share, owned by the caption. The rig proves the
  chooser opened; only WhatsApp shows what actually went.
- **A real low-memory kill.** `process_death.yaml` force-stops, which is cleaner than an LMK kill —
  no saved instance state, no restored back stack.
- **The static-apply crop.** Proving the subject is not cut needs a launcher screencap
  template-matched against the source.
