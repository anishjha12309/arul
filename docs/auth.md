# Sign-in — the Credential Manager contract

Read before touching `lib/features/auth/**`, `lib/core/auth/**`, `workers/src/routes/auth.ts` or
`workers/src/lib/{google,jwt}.ts`. Cold-start ordering and the splash's auth gate live in
[launch-surface.md](launch-surface.md); the events these paths emit are in
[analytics-events.md](analytics-events.md).

Sign-in is the whole install→login funnel, and every failure here is silent by nature: Credential
Manager reports a configuration error and a user dismissal with the same code.

## One visible Google surface per attempt

- **Auto-launch a Google surface on the first frame — never a silent, no-UI check.** `google_sign_in`
  v7: `instance` → `initialize()` → surface. The idToken's `aud` is the WEB client id, verified in
  the Worker against Google's JWKS.
- **Sheet first, picker second**, per Google's SIWG implementation guide:
  `attemptLightweightAuthentication(reportAllExceptions: true)` — natively a filtered, auto-select
  `GetGoogleIdOption` then an unfiltered one — so a returning user with one authorized account is
  signed in without ever seeing a picker.
- **`reportAllExceptions` is required.** The plugin's default folds `canceled`/`interrupted`/
  `uiUnavailable` into a null result, which makes a DISMISSED sheet indistinguishable from an empty
  one — and would put the picker up over a sheet the user just closed.
- **The picker follows the sheet only when the sheet drew NOTHING or could not COMPLETE.** Nothing =
  a null result (no accounts, "Sign-in prompts" disabled, no credential after both native steps).
  Could-not-complete = `uiUnavailable`, `interrupted`, or a GMS `TransactionTooLargeException`
  surfacing as `unknownError`; those track `sheet_unavailable` and hand over to the button. A failure
  AFTER the user picked an account counts as could-not-complete — an offline token mint looks exactly
  like a sheet that never drew, and the ask was to sign in.
- **A DISMISSED sheet (`canceled`) STOPS the attempt** — nudge, no picker. The Credential Manager
  troubleshooting guide forbids automatically retrying a cancellation.
- **A pill tap SKIPS the sheet** (`signInWith(auto: false)`). Google's stated reasons for the button
  flow — sheet dismissed, no Google accounts, accounts needing re-auth — are exactly why the user is
  tapping.
- **Sheet-first is not the reverted warm-up.** The warm-up ran the sheet *ahead of* a picker it was
  always going to open: the user saw a drawer appear, hang and vanish, plus seconds of stall-guard
  dead air. Warm-ups stay forbidden; a sheet that IS the attempt is the guide's own order.
- Kill switch is one `static const bool sheetFirst` beside `_signInWithGoogle`; false = button flow
  only. Deliberately a BUILD revert and **not** a `feature_flags` entry — `catalog/app_config.json`
  is not on disk on a first launch, and the first launch is the whole funnel.

`resolveGoogleCredential` is pure and pinned test-side; keep it that way.

## The nonce

Every ID token carries a nonce and the Worker checks it: 32 bytes from `Random.secure()`, unpadded
base64url, generated ONCE per process in `main()` and handed to `initialize()` — the only place the
plugin accepts one. So the guarantee is "only the process that requested this token can redeem it",
never "redeemable once".

`POST /auth/login` sends the same value; `handleLogin` 401s `nonce_mismatch` unless the request nonce
and the token claim are equal, **with BOTH ABSENT accepted** so every build already in the field
keeps signing in. Checking the PAIR — not merely "did the body send one" — is what rejects a
new-build token replayed through an old-shaped request. Never log, toast or track the value.

## Reading the failure buckets

**`login_cancelled` is a MIXED bucket — never read it as "users who dismissed the sheet".** Per
`google_sign_in_android`'s own README, a configuration error (wrong signing SHA for one build
config, wrong package name server-side, wrong `serverClientId`) makes Credential Manager return
`canceled` *after the user has already picked an account*, and the plugin cannot distinguish that
from a real cancellation.

Split on the message TEXT first and timing second — timing alone under-splits, because the clock
starts at the auto-launch, not at the sheet, so a scripted dismissal lands inside the failure band.
**The two events spell the message differently**: `login_cancelled` carries `description`,
`login_failed` carries `error`. A query that splits "on `description`" returns nothing for
`login_failed`.

## Failure handling

- Classify `GoogleSignInException` by its typed `code` only. `canceled` is the one quiet outcome
  (tracked `login_cancelled`); every other code toasts and tracks `login_failed` with `gis_code`.
  A string-sniff for "cancel" swallowed real failures — an LTE token-mint death read as a cancel.
- **EVERY failure return goes through `_googleFailure`.** Six of them once showed an error and told
  analytics nothing, which is the same funnel hole by another route.
- **A 30 s CONTINUOUS-FOREGROUND stall abandons the attempt** (`abandonPendingSignIn` — the zombie's
  late result is discarded before any side effect) and re-arms the pill. Credential Manager can drop
  its callback outright, and the busy pill ignores taps. Inactive/paused/hidden EXTENDS, never
  abandons — a user reading the account list is not a stall — and returning to the foreground
  RESTARTS the clock. Without that, a user who sat in the sheet past the budget had a live token
  exchange abandoned milliseconds before it completed: session landed, `login_success` fired, and the
  screen still showed "taking too long" one tap from a second picker over a live session.
- A cancel stays TOAST-less but is not a silent bounce: the pill subtitle flips to the retry nudge.
  **Never auto-relaunch on a cancel.**
- **`POST /auth/login` retries connectivity-class failures only** — ≤3 attempts, 15 s elapsed cap,
  1.5 s backoff, so the worst case stays inside the 30 s stall budget. A server RESPONSE is never
  retried. GMS survives blackouts this POST does not, and a lost exchange must never cost the user a
  second picker.
- **Sign-out and delete-account call the plugin's `signOut()`** = Credential Manager
  `clearCredentialState()`, so providers drop their stored session and a user who signed out to
  switch accounts is not handed the same account again. Best-effort AFTER the local session is
  cleared; a plugin error must never strand the user signed in.
- Auth strings stay authored-English ("localized-enough") — the one exception to the all-6-locales
  rule.

## Session

JWT HS256: access 60 m, refresh 60 d rotating, old jti denylisted in KV. **Entitlement is never
authoritative in the token** — the `prm` claim is a UI hint; see
[architecture.md](architecture.md) §Entitlement.

The sign-in background video is a shared ref-counted player with a 2 s dispose grace, so a screen
swap cannot kill it.
