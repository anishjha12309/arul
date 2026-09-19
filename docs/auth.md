# Sign-in — the Credential Manager contract

Read before touching `lib/features/auth/**`, `lib/core/auth/**`, `workers/src/routes/auth.ts` or
`workers/src/lib/{google,jwt}.ts`. Cold-start ordering and the splash's auth gate:
[launch-surface.md](launch-surface.md). Events: [analytics-events.md](analytics-events.md).

Sign-in is the whole install→login funnel, and every failure is silent: Credential Manager reports a
config error and a user dismissal with the same code.

## One visible Google surface per attempt

- **Auto-launch a Google surface on the first frame — never a silent, no-UI check.** `google_sign_in`
  v7: `instance` → `initialize()` → surface. The idToken's `aud` is the WEB client id, verified in the
  Worker against Google's JWKS.
- **Sheet first, picker second**, per Google's SIWG guide:
  `attemptLightweightAuthentication(reportAllExceptions: true)` — natively a filtered, auto-select
  `GetGoogleIdOption` then an unfiltered one — so a returning user with one authorized account signs
  in without ever seeing a picker.
- **`reportAllExceptions` is required.** The plugin's default folds `canceled`/`interrupted`/
  `uiUnavailable` into a null result, making a DISMISSED sheet indistinguishable from an empty one,
  so the escalation could not be told from a plain fall-through, and no `login_cancelled`.
- **The picker follows the sheet only when it drew NOTHING or could not COMPLETE.** Nothing = a null
  result (no accounts, "Sign-in prompts" disabled, no credential after both native steps).
  Could-not-complete = `uiUnavailable`, `interrupted`, or a GMS `TransactionTooLargeException`
  surfacing as `unknownError`; those track `sheet_unavailable` and hand to the button. A failure
  AFTER the user picked counts as could-not-complete — an offline token mint looks exactly like a
  sheet that never drew.
- **A DISMISSED sheet (`canceled`) escalates ONCE to the BUTTON flow, never to a second One Tap
  pass.** Both `GetGoogleIdOption` passes are ONE rate-limited surface: cancel it a few times in a
  row and GMS stops drawing it for 24 h, which takes AUTOMATIC sign-in with it.
  `GetSignInWithGoogleOption` is the remedy Google's guide names for a dismissal and is not that
  surface. Reports `surface=button_after_dismiss` so the second chance can be priced. The cooldown
  resets by clearing GMS storage, or toggle it from the dialer: `*#*#66382723#*#*`.
- **Google's surfaces live INSIDE this app's task and outlive its process.** Swipe home out of a
  picker, lose the process, tap the icon: Android resumes the dead picker with no app behind it, and
  a pick lands on the home screen (reproduced on device). `clearTaskOnLaunch` on `MainActivity`
  strips everything above it on an icon launch; recents are untouched. Keep it.
- **A pill tap SKIPS the sheet** (`signInWith(auto: false)`). Google's stated reasons for the button
  flow — sheet dismissed, no accounts, accounts needing re-auth — are exactly why the user taps.
- **Sheet-first is not the reverted warm-up**, which ran the sheet *ahead of* a picker it would open
  anyway — a drawer that appeared, hung and vanished, plus stall-guard dead air. Warm-ups stay
  forbidden; a sheet that IS the attempt is the guide's own order.
- Kill switches beside `_signInWithGoogle`: `sheetFirst` (false = button only) and
  `pickerAfterDismiss` (false = a dismissal ends the attempt). BUILD reverts, **not** `feature_flags`
  — `catalog/app_config.json` is not on disk on a first launch.

`resolveGoogleCredential` is pure and pinned test-side; keep it so.

## The nonce

Every ID token carries a nonce and the Worker checks it: 32 bytes from `Random.secure()`, unpadded
base64url, generated ONCE per process in `main()` and handed to `initialize()` — the only place the
plugin accepts one. The guarantee is "only the process that asked for this token can redeem it",
never "redeemable once".

`POST /auth/login` sends the same value; `handleLogin` 401s `nonce_mismatch` unless the request nonce
and the token claim are equal, **with BOTH ABSENT accepted** so every fielded build keeps signing in.
Checking the PAIR — not merely "did the body send one" — rejects a new-build token replayed through
an old-shaped request. Never log, toast or track the value.

Reading `login_cancelled`/`login_failed` correctly is an analytics trap, not a code rule:
[analytics-ops.md](analytics-ops.md) §Reading the data.

## What the screen may say about a failed attempt

**ONE line, the same for every failure — the retry line. No sentence under the pill, no link out of
the app** (owner's call: lines naming Play services or account settings were noise to an audience
that cannot act on them; all any of them can do is tap again). Never re-add a fix line or a help
link. The outcome (`classifySignInOutcome`, `domain/sign_in_outcome.dart`) still
rides `AuthCancelled` into `login_cancelled` as `nudge`, pinned string by string in both of Google's
spellings: MESSAGE first, then the backed-out family split on **`ms_to_surface`** — wall-clock from
`authenticate()` to the attempt's FIRST inactive/paused/hidden, the only signal the app gets that
Google's surface came up. Null means none was ever seen; 8 s separates the user's back-out from the
phone's wait. `providerConfigurationError` routes off the
failure KIND, never a message; an unrecognised message classifies as nothing.

- **The type is a FIXED size on every phone and the LAYOUT absorbs a long translation** (owner's
  call: handle it the way a shipped app does, not by resizing the screen). The sizes live as
  constants at the top of `sign_in_screen.dart`, set against Google's own sheet, which lands on this
  screen at ~16 sp rows. The panel's 18 dp side padding may not grow: every dp of it leaves the
  pill's 180 dp slot.
- **The two lines absorb it differently, because their jobs do.** The title is a button label and
  stays one line — `scaleDown` is its handling. The subtitle is a sentence, so it WRAPS and the pill
  grows: at most two lines at text scale 1.0 and three at 1.3 on the phones the size matrix covers,
  a fourth for the 320 dp frame where the slot is 140 dp and wrapping is word-bounded. Nothing
  truncates — no ellipsis on either line. `sign_in_size_matrix_test.dart` enforces it.
- **The pill is the ONLY tappable thing on the wall — never add a second control.** Google's sheet
  lands ON this screen and covers it, so anything else is reached by dismissing the sheet first: the
  bottom-left language chip that once sat here pushed first-sheet sign-ins down and pill taps up, and
  its users made roughly twice the attempts and signed in far less. A fresh install opens in its
  REGION's language ([deep-links.md](deep-links.md)); Settings is the one place it changes.
- **Nothing else on the wall is tappable** — the Terms · Privacy footer stays gone; Play's in-app
  privacy-policy requirement is met by Settings. The wordmark stays English and is the wall's only
  mark; the eyebrow is the splash's alone. **Icon glyphs take NO `shadows`:** Impeller paints a
  second mark beside a shadowed icon FONT; text shadows are fine.

## Failure handling

- Classify `GoogleSignInException` by its typed `code` only. `canceled` is the one quiet outcome
  (tracked `login_cancelled`); every other code toasts and tracks `login_failed` with `gis_code`. A
  "cancel" sniff swallowed real failures — an LTE token-mint death read as one.
- **EVERY failure return goes through `_googleFailure`** — six once errored and told analytics
  nothing.
- **A 30 s CONTINUOUS-FOREGROUND stall abandons the attempt** (`abandonPendingSignIn` — the zombie's
  late result is dropped before any side effect) and re-arms the pill. Credential Manager can drop
  its callback outright, and the busy pill ignores taps. Inactive/paused/hidden EXTENDS, never
  abandons — a user reading the account list is not a stall.
- **Resuming is not progress; a live exchange is.** Split the return on `SignInPhase.exchanging`.
  TRUE = `POST /auth/login` in flight → RESTART the full clock, or it dies milliseconds before it
  lands and `login_success` fires while the screen says "taking too long". FALSE = nothing of ours
  runs and no Google surface is on top (one would keep us inactive), so the sheet is GONE — a
  destroyed `CredentialSelectorActivity` completes its continuation never: no result, no cancel, no
  exception. Allow `stallResumeGrace` (2 s), all a real back-from-sheet outcome needs, then abandon
  as `stalled_resumed`; a full budget spins the pill 30 s over a corpse. Re-read the lifecycle AFTER
  the grace — returning by RECENTS puts the sheet back on top, which is mid-flow again.
  **The guard reads the lifecycle every 250 ms, never once per budget:** it once slept through the
  whole 30 s and a Home-and-back inside it was invisible — sheet, picker and mid token-mint all spun
  to "taking too long" on device.
- **An icon tap on a live task is the OS, not the user.** `clearTaskOnLaunch` strips Google's
  surface: a stripped sheet delivers nothing (the grace path), a stripped PICKER delivers a
  `canceled` nobody made. The launcher brings the task forward WITHOUT `onNewIntent` (measured), so
  the tell is the wording: a user's back-out of the picker says `[16] Cancelled by user`, the
  framework closing the session says `User cancelled the selector` — on the BUTTON surface that is
  `SignInOutcome.selectorStripped` and relaunches once as `surface_stripped`; on the sheet the
  same words are the user's swipe. Recents keeps the surface and needs none of this.
- A cancel stays TOAST-less; the retry line is the only feedback. **A DISMISSED sheet is never
  auto-relaunched; a LOST callback is relaunched ONCE**, one-shot so a second cannot loop. A user's
  cancel SETTLES the future inside the grace and never reaches that path; the launcher's
  manufactured cancel is the one exception, because there was no cancellation to honour.
- **A return from Google's add-account flow reopens the PICKER once** (`auto: false`, never the
  sheet; files under `surface=button_after_add_account`). Credential Manager reports ONE string,
  `[16] User cancelled during add account flow and accounts were present`, whether the person added
  an account, backed out, or was bounced: GMS's "Checking info…" step opens its own "verify it's
  you" BiometricPrompt, which on an unattended device was seen BOTH cancelling itself within two
  seconds and waiting for a finger — a hands-off adb walk of this flow proves nothing about what a
  person holding the phone gets. The app makes one `authenticate()` and only receives that cancel:
  it cannot tell the cases apart. The result lands a beat before our resume, so
  the reopen waits `stallResumeGrace` for the foreground and opens nothing from behind another app.
- **`providerConfigurationError` on Android 13 and below is Play services under Credential
  Manager's floor**: androidx.credentials gates on `isGooglePlayServicesAvailable(context,
  MIN_GMS_APK_VERSION)` and throws below it. Check against THAT number (`PlayServicesChannel`), not
  the default — play-services-base accepts a far older Play services and calls a broken phone
  healthy. Below it, show Google's error dialog and wait for nothing: the person's return from the
  Play Store is a return to the wall or a cold start, both of which already sign in.
- **A RETURN to the wall re-arms the automatic sheet ONCE** (`AuthController.noteAppLifecycle`, fed
  by the screen's observer; the screen decides nothing). A person who left and came back is not the
  cancel case, and a share of logins only ever land on such a return. Conditions, all required:
  paused/hidden stretch ≥ `returnAwayThreshold` (20 s) that BEGAN after the last outcome settled,
  ≥ `returnCooldown` (60 s) since that outcome, nothing in flight, signed out. `inactive` is a
  Google surface or a dialog, never "away". Lock/unlock counts as a return. The attempt files under
  `surface=sheet_return` so the return surface is priced apart from the cold-start sheet.
- **`POST /auth/login` retries connectivity-class failures only** — ≤3 attempts, 15 s elapsed cap,
  1.5 s backoff, so the worst case stays inside the 30 s stall budget. A server RESPONSE is never
  retried. GMS survives blackouts this POST does not, and a lost exchange must never cost a picker.
- **Sign-out and delete-account call the plugin's `signOut()`** = Credential Manager
  `clearCredentialState()`, so providers drop their stored session and a user who signed out to
  switch accounts is not handed the same one. Best-effort AFTER the local clear; a plugin error must
  never strand the user signed in.
- **The sign-in SCREEN is localized in all six; the failure TOASTS are not.** Everything on the wall
  but the wordmark comes from the ARBs. `AuthFailure.message` stays authored-English
  ("localized-enough") — the one exception left to the all-6-locales rule.

## Session

JWT HS256: access 60 m, refresh 60 d rotating, old jti denylisted in KV. **Entitlement is never
authoritative in the token** — `prm` is a UI hint ([architecture.md](architecture.md) §Entitlement).
The sign-in background video is a shared ref-counted player with a 2 s dispose grace, so a screen
swap cannot kill it.
