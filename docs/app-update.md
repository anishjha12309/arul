# In-app update

Play's In-App Updates API through our own `update/AppUpdateChannel.kt` (app-update 2.1.0, the floor
Play requires at targetSdk 34+) and `lib/features/app_update/`. The policy is the pure `decide()` in
`app_update_policy.dart`; its test is the contract.

## When it asks

- **Cold start**: 1.5 s after the splash leaves `/`, so autoSignIn's hold already exists.
- **Resume**: after 60 s or more away, never on the resume that returns from Play's own screen.
  Without that rule, cancel → resume → prompt loops.
- **Hold release**: 2 s after the last hold drops, if a check was deferred.

## When it never asks

`UpdateHolds` (lib/core/update) is held while a sign-in attempt is in flight and while `/premium`
is mounted, which covers the paywall, the UPI handoff, the QR and the return page. The splash (`/`)
and the sign-in wall (`/sign-in`) are never covered, even between attempts (docs/auth.md): a check
due there waits for the next route change. An apply, share or ringtone set still loading defers it
too (a restart loses it, and the live chooser backgrounds us), polled every 2 s since those finish
without notifying. The check also
needs lifecycle `resumed`: Google's sheet and system dialogs leave the app `inactive`. A check deferred
that way retries 2 s after the next resume. Without that retry, the notification ask right after
sign-in swallowed the session's prompt (seen on device). A downloaded
FLEXIBLE update installs through `completeUpdate()` only on a background with no holds. Play installs
it silently there, so the app shows no restart prompt of its own.

## What it asks for

- IMMEDIATE when Play allows it, else FLEXIBLE.
- A declined prompt returns on the next cold start, or on a resume once `reprompt_minutes` have
  passed.
- An interrupted IMMEDIATE update (`DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS`) is resumed, as the Play
  docs require. Play reports a FLEXIBLE download with the same status, so an accepted flexible flow
  is remembered (`arul_update_flexible_started`) and never resumed as IMMEDIATE.
- `updatePriority()` and `clientVersionStalenessDays()` are unused: priority is settable only through
  the Play Developer API, and the CMS `mode` already picks the flow.

## The review sheet yields

Both are Play overlays asked at a cold open, so the update wins the launch. `UpdateHolds.launch`
starts `undecided` on a Play install. The review trigger waits for it to leave that state, and
skips the whole launch (arm kept) if it is `prompted`. A sideload, a found-nothing check and any
failure set it `clear`.

## Server knobs (no Worker change, no app release)

- `feature_flags.app_update = {"mode": "immediate"|"flexible"|"off", "reprompt_minutes": 30}` in the
  CMS "Advanced settings" JSON. It reaches the app through the catalog's `app_config.json`.
- `min_supported_version` (CMS Config page) is read as a **build number**: `85` or `1.0.0+85`.
  Below it, every check prompts, and neither the mode nor the cooldown applies. Any other value is
  no floor, including the historic `1.0.0`. Builds ≤ 84 ignore the field entirely.
- It is not a blocking screen: Play offers nothing during a staged or halted rollout, so a hard
  block would strand users.

## Test it on a sideload

Play never offers an update to a sideload, so the channel swaps in Play's own `FakeAppUpdateManager`
when a NON-Play install is launched with an extra. A Play install ignores the extra.

```bash
adb shell am force-stop com.hsrutility.arul
adb shell am start -n com.hsrutility.arul/.MainActivity --es arul_fake_update immediate_accept
adb logcat -s ArulUpdate:W   # check -> flow started -> accepted -> result -> download completed
```

- **Modes:** `immediate_accept`, `immediate_cancel`, and `flexible` (the download completes, then
  Home triggers `completeUpdate`).
- **What `immediate_cancel` proves:** a return within 60 s is silent. A return after 60 s or more
  checks but does not prompt (30 min cooldown). A cold start prompts again.
- **Seeing the GA4 events:** `setprop log.tag.FA-SVC VERBOSE` shows `app_update_prompt` and
  `app_update_result`.

## Traps

- Sideloads, debug builds, emulators and `flutter test` no-op. The API errors there (APP_NOT_OWNED,
  API_NOT_AVAILABLE) and `PlayInstall.isPlay` gates the bootstrap. Test through internal app sharing
  with a lower versionCode installed.
- Builds ≤ 84 carry no update code. Only Play's own auto-update reaches them.
- Events are GA4 only (`app_update_prompt`, `app_update_result`, all string params). PostHog
  already splits every journey event by `$app_build`.
