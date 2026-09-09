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
  and would put the picker over a sheet the user just closed.
- **The picker follows the sheet only when it drew NOTHING or could not COMPLETE.** Nothing = a null
  result (no accounts, "Sign-in prompts" disabled, no credential after both native steps).
  Could-not-complete = `uiUnavailable`, `interrupted`, or a GMS `TransactionTooLargeException`
  surfacing as `unknownError`; those track `sheet_unavailable` and hand to the button. A failure
  AFTER the user picked counts as could-not-complete — an offline token mint looks exactly like a
  sheet that never drew, and the ask was to sign in.
- **A DISMISSED sheet (`canceled`) STOPS the attempt** — nudge, no picker. The Credential Manager
  guide forbids automatically retrying a cancellation.
- **Google's surfaces live INSIDE this app's task and outlive its process.** Swipe home out of a
  picker, lose the process, tap the icon: Android resumes the dead picker with no app behind it, and
  a pick lands on the home screen (reproduced on device). `clearTaskOnLaunch` on `MainActivity`
  strips everything above it on an icon launch; recents are untouched. Keep it.
- **A pill tap SKIPS the sheet** (`signInWith(auto: false)`). Google's stated reasons for the button
  flow — sheet dismissed, no accounts, accounts needing re-auth — are exactly why the user taps.
- **Sheet-first is not the reverted warm-up**, which ran the sheet *ahead of* a picker it was always
  going to open: a drawer that appeared, hung and vanished, plus seconds of stall-guard dead air.
  Warm-ups stay forbidden; a sheet that IS the attempt is the guide's own order.
- Kill switch is one `static const bool sheetFirst` beside `_signInWithGoogle`; false = button flow
  only. A BUILD revert, **not** a `feature_flags` entry — `catalog/app_config.json` is not on disk on
  a first launch, and the first launch is the whole funnel.

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

## Reading the failure buckets

**`login_cancelled` is a MIXED bucket — never read it as "users who dismissed the sheet".** Per
`google_sign_in_android`'s README, a config error (wrong signing SHA, wrong package name
server-side, wrong `serverClientId`) makes Credential Manager return `canceled` *after the user
picked an account*, and the plugin cannot tell that from a real cancellation.

Split on the message TEXT first, timing second — timing alone under-splits: the clock starts at the
auto-launch, not the sheet, so a scripted dismissal lands inside the failure band.
**The two events spell the message differently**: `login_cancelled` carries `description`,
`login_failed` carries `error`. A query that splits "on `description`" returns nothing for
`login_failed`.

## What the screen may say about a failed attempt

**ONE line, the same for every failure — the retry line. No sentence under the pill, no link out of
the app** (owner's call: three lines naming Play services or account settings were noise to an
audience that cannot act on them, and the only thing any of them can do is tap again). Never re-add a
fix line or a help link. The outcome (`classifySignInOutcome`, `domain/sign_in_outcome.dart`) still
rides `AuthCancelled` into `login_cancelled` as `nudge`, pinned string by string in both of Google's
spellings: MESSAGE first, then the backed-out family split on **`ms_to_surface`** — wall-clock from
`authenticate()` to the FIRST inactive/paused/hidden of the attempt, the only signal the app gets
that Google's surface came up, a GMS activity over ours. Null means no surface was ever seen; 8 s
separates the user's back-out from the phone's wait. `providerConfigurationError` routes off the
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
- **No language control on the wall** (owner's call). The wall follows the phone's language and the
  picker lives in Settings only; a footer chip was tried and pulled — it never moved sign-in and it
  was a second tappable thing beside the one button that matters. **Nothing else on the wall is
  tappable either** — the Terms · Privacy footer went for the same reason, and Play's in-app
  privacy-policy requirement is met by Settings, which every signed-in user reaches. The wordmark stays English and is
  the wall's only brand mark; the eyebrow under it is the splash's alone.
  **Icon glyphs take NO `shadows`:** Impeller paints a second mark beside a shadowed icon FONT; text
  shadows are fine.

## Failure handling

- Classify `GoogleSignInException` by its typed `code` only. `canceled` is the one quiet outcome
  (tracked `login_cancelled`); every other code toasts and tracks `login_failed` with `gis_code`. A
  "cancel" sniff swallowed real failures — an LTE token-mint death read as a cancel.
- **EVERY failure return goes through `_googleFailure`.** Six once errored and told analytics
  nothing — the same funnel hole by another route.
- **A 30 s CONTINUOUS-FOREGROUND stall abandons the attempt** (`abandonPendingSignIn` — the zombie's
  late result is dropped before any side effect) and re-arms the pill. Credential Manager can drop
  its callback outright, and the busy pill ignores taps. Inactive/paused/hidden EXTENDS, never
  abandons — a user reading the account list is not a stall — and returning to the foreground
  RESTARTS the clock. Without that, a user who sat in the sheet past the budget had a live exchange
  abandoned milliseconds before it landed: `login_success` fired while the screen said "taking too
  long", a tap from a second picker over a live session.
- A cancel stays TOAST-less; the retry line under the pill is the only feedback. **Never
  auto-relaunch on a cancel.**
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
