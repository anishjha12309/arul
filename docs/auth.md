# Sign-in — the Credential Manager contract

Read before touching `lib/features/auth/**`, `lib/core/auth/**`, `workers/src/routes/auth.ts` or
`workers/src/lib/{google,jwt}.ts`. Sign-in is the whole install→login funnel and every failure is
silent. Cold-start ordering: [launch-surface.md](launch-surface.md) · the wall's re-arms and copy:
[sign-in-wall.md](sign-in-wall.md) · events: [analytics-events.md](analytics-events.md).

## One visible Google surface per attempt

- **Auto-launch a Google surface on the first frame — never a silent, no-UI check.** `google_sign_in` v7:
  `instance` → `initialize()` → surface. The idToken's `aud` is the WEB client id, verified in the
  Worker against Google's JWKS.
- **Sheet first, picker second**, per Google's guide:
  `attemptLightweightAuthentication(reportAllExceptions: true)` — natively a filtered auto-select
  `GetGoogleIdOption`, then an unfiltered one — so a returning one-account user signs in without a picker.
  **`reportAllExceptions` is required:** the default folds `canceled`/`interrupted`/`uiUnavailable` into
  null, making a DISMISSED sheet indistinguishable from an empty one.
- **The picker follows the sheet only when it drew NOTHING or could not COMPLETE.** Nothing = a null
  result (no accounts, "Sign-in prompts" off). Could-not-complete = `uiUnavailable`, `interrupted`, or a
  GMS `TransactionTooLargeException` surfacing as `unknownError` — tracked `sheet_unavailable`. A failure
  AFTER the user picked counts as could-not-complete: an offline token mint looks like a sheet that
  never drew.
- **A DISMISSED sheet (`canceled`) escalates ONCE to the BUTTON flow, never to a second One Tap pass.**
  Both `GetGoogleIdOption` passes are ONE rate-limited surface: a few cancels in a row and GMS stops
  drawing it for 24 h, taking AUTOMATIC sign-in with it. `GetSignInWithGoogleOption` is Google's remedy
  for a dismissal. Reset the cooldown by clearing GMS storage or dialling `*#*#66382723#*#*`.
- **A pill tap SKIPS the sheet** (`signInWith(auto: false)`): the reasons Google gives for the button
  flow are exactly why the user taps.
- **Never a warm-up** — a sheet run ahead of a picker it would open anyway was a drawer that appeared,
  hung and vanished. A sheet that IS the attempt is the guide's own order.
- Kill switches `sheetFirst` and `pickerAfterDismiss` are BUILD consts, **not** `feature_flags` —
  `catalog/app_config.json` is not on disk on a first launch. `resolveGoogleCredential` is pure and
  pinned test-side; keep it so.

## Google's surfaces live INSIDE this app's task

Credential Manager launches them from the activity context, so they outlive the process: Home, lose the
process, tap the icon, and the dead picker returns with no app behind it.

- `clearTaskOnLaunch` on MainActivity strips everything above it on an icon launch (Recents untouched).
  Keep it — it acts on the task ROOT only.
- **A death WHILE the surface is in front (crash, ANR close, force-stop) makes Google's selector the
  ROOT**, and the icon brought back the dead sheet — Continue went nowhere. `singleInstancePerTask`
  never reuses a task whose root is not MainActivity, so the icon opens a fresh Arul. Reproduce with
  `am crash`; plain `am kill` spares a visible process.
- **`launchMode` is `@integer/main_launch_mode`: `singleInstancePerTask` in `values-v31`, singleTop
  below.** API ≤30 reads the raw value as `standard` (a second app stacked on a warm link, a restart on
  a push tap), so ≤11 keeps the dead sheet ([known-issues.md](known-issues.md)). Never `singleTask`
  (AOSP `complyActivityFlags`): it adds MainActivity ABOVE the dead root and the next icon tap
  finishes it.

## The nonce

32 bytes from `Random.secure()`, unpadded base64url, generated ONCE per process in `main()` and handed
to `initialize()` — the only place the plugin accepts one. The guarantee is "only the process that asked
for this token can redeem it", never "redeemable once". `POST /auth/login` sends the same value;
`handleLogin` 401s `nonce_mismatch` unless request nonce and token claim are equal, **with BOTH ABSENT
accepted** so fielded builds keep signing in. Checking the PAIR rejects a new-build token replayed
through an old-shaped request. Never log, toast or track the value.

## Failure handling

- **Classify `GoogleSignInException` by its typed `code` only.** `canceled` is the one quiet outcome
  (`login_cancelled`); every other code toasts and tracks `login_failed` with `gis_code`. A "cancel"
  string sniff swallowed real failures. **EVERY failure return goes through `_googleFailure`.**
- **A 30 s CONTINUOUS-FOREGROUND stall abandons the attempt** (`abandonPendingSignIn` drops the late
  result before any side effect) and re-arms the pill: Credential Manager can drop its callback
  outright. Inactive/paused/hidden EXTENDS, never abandons. **The guard reads the lifecycle every
  250 ms** — reading once per budget slept through a Home-and-back and spun to "taking too long".
- **Resuming is not progress; a live exchange is.** Split the return on `SignInPhase.exchanging`: TRUE =
  `POST /auth/login` in flight → RESTART the clock, or `login_success` fires under "taking too long".
  FALSE with no Google surface on top means the sheet is GONE — a destroyed `CredentialSelectorActivity`
  completes its continuation never. Wait `stallResumeGrace` (2 s), re-read the lifecycle (Recents puts
  the sheet back), then abandon as `stalled_resumed`.
- **An icon tap on a live task is the OS, not the user.** `clearTaskOnLaunch` strips Google's surface: a
  stripped sheet delivers nothing (the grace path), a stripped PICKER delivers a `canceled` nobody made.
  The tell is the wording — a user's back-out says `[16] Cancelled by user`, the framework's close says
  `User cancelled the selector`. On the BUTTON surface that is `selectorStripped` and reopens the PICKER
  once as `surface_stripped`, never the sheet already dismissed. Below Android 14 the American
  `User canceled the selector` is Play services' own `identitycredentials` selector (androidx.credentials 1.6
  routes through it on GMS ≥ 25.24).
- **A DISMISSED sheet is never auto-relaunched; a LOST callback is relaunched ONCE**, one-shot. A cancel
  stays toast-less.
- **No network at all when the automatic sheet comes due HOLDS it** (`autoSignIn(offline: true)`) —
  offline the sheet draws only to fail. Hold on a KNOWN `none` reading only; loading or errored reads
  online, and the splash waits at most 150 ms. `LaunchLinkProbe` asks in `main()` and the splash LISTENS
  to `isOnlineProvider` — Riverpod 3 pauses an unlistened provider, so a bare read never answered. The
  link coming up or ANY resume releases it once as `sheet_after_offline`.
- **A pill tap on a KNOWN `none` reading is PARKED, not run** (`holdTapForNetwork`): offline the picker
  fails in ~2 s as `[16] Account reauth failed` and people tapped it over and over. The screen re-reads
  `checkConnectivity()` first so a stale stream never parks a live phone. Link-up or a resume releases it
  as the PICKER (`button_after_offline`), never the sheet; over a held launch the launch wins.
- **`POST /auth/login` retries connectivity-class failures only** — ≤3 attempts, 15 s cap, 1.5 s
  backoff, inside the 30 s stall budget. A server RESPONSE is never retried; GMS survives blackouts
  this POST does not, and a lost exchange must never cost a picker. A TLS failure is connectivity
  (`http`'s IOClient passes it through raw). An attempt pending 8 s gets ONE sibling beside it, never
  instead: on 2G the first is nearly through. The Worker's 503 `google_keys_unavailable` is retried —
  the token was never judged. The upsert makes a hedged pair land on one user id.
- **Login ignores `referralCode`** (owner: capture stopped; old builds still send one). Never re-add a
  capture step: `referral_code` is still minted for old builds' Refer screen.
- **The picker coming back `unknownError` "No credential available" is Play services missing
  Credential Manager's 3 s deadline** (cold GMS), never an empty phone — with no account the button
  flow opens add-account. The guard re-asks the PICKER once (`button_after_timeout`); the next query
  answers in ~0.1 s. Matched on that text, never on a clock.
- **`providerConfigurationError` on Android ≤13 is Play services under Credential Manager's floor**:
  androidx.credentials checks `isGooglePlayServicesAvailable(context, MIN_GMS_APK_VERSION)`. Check THAT
  number (`PlayServicesChannel`) — play-services-base's default calls a broken phone healthy — then show
  Google's error dialog and wait for nothing.
- **Sign-out and delete call the plugin's `signOut()`** (`clearCredentialState()`) so a user switching
  accounts is not handed the same one — best-effort AFTER the local clear.

## Reading the failure buckets

**`login_cancelled` is a MIXED bucket — never read it as "users who dismissed the sheet".** Per
`google_sign_in_android`'s README a config error (wrong signing SHA, package or `serverClientId`)
returns `canceled` *after the user picked an account*. Split on the message TEXT first
(`classifySignInOutcome`, pinned in both of Google's spellings), timing second — `ms_to_surface`, from
`authenticate()` to the attempt's first inactive/paused/hidden; 8 s separates a back-out from the
phone's wait. Timing alone under-splits. **`login_cancelled` carries `description`, `login_failed`
carries `error`** — a query splitting on `description` returns nothing for failures.

## Session

Token lifetimes and the `prm` hint: [architecture.md](architecture.md) §Security. **A refresh that proves
the session dead ends it mid-use** (`ApiClient.sessionEnded` → the wall, automatic sheet re-armed);
Credential Manager state is left alone, so a one-account phone signs straight back in. Where tokens live
when the Keystore refuses: [launch-surface.md](launch-surface.md). The sign-in background video is one
shared ref-counted player with a 2 s dispose grace, so a screen swap cannot kill it.
