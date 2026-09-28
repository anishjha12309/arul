# The sign-in wall — when it re-launches Google, and what it may say

Read before touching `sign_in_screen.dart` or the re-arm logic in `auth_providers.dart`. The
Credential Manager flow, the stall guard and failure classification: [auth.md](auth.md).

## When the wall launches Google again

Google's guide forbids an automatic retry after a user's CANCELLATION and only that. Every re-arm below
fires at most as stated, and each files under its own `surface` so it can be priced apart
([analytics-events.md](analytics-events.md)).

- **A RETURN to the wall re-arms the automatic sheet ONCE** (`AuthController.noteAppLifecycle`, fed by
  the screen's observer; the screen decides nothing). A person who left and came back is not the cancel
  case, and some logins only ever land on such a return. All required: a paused/hidden stretch
  ≥ `returnAwayThreshold` (20 s) that BEGAN after the last outcome settled, ≥ `returnCooldown` (60 s)
  since that outcome, nothing in flight, signed out. `inactive` is a Google surface or a dialog, never
  "away"; lock/unlock counts as a return. `surface=sheet_return`.
- **A RECONNECT re-arms it once more** (`AuthController.noteConnectivity`, fed by `isOnlineProvider`).
  Mobile data off: the sheet draws, the account tap dies in Play services
  (`[28404] Failed to retrieve an ID token`), the picker dies the same way — then data returns and nothing
  happens. All required: an offline→online transition (transport-level — Wi-Fi with no internet reads
  online); a last outcome of `networkError` or `unknown`, or the picker's offline cancel
  `[16] Account reauth failed` (no other cancel, nor `noPlayServices`, `serverError`,
  `tokenExchangeFailed`); landing after that outcome settled; nothing in flight; signed out; our UI RESUMED.
  ONE per failure, TWO per signed-out stretch, or a flapping link loops the sheet. `listenManual` reports
  changes only, so a wall that MOUNTS offline records the reading itself or the return of the link is no
  transition. A link back while we are PAUSED (data turned on in Settings) is kept for the next resume,
  and dropped by a new offline reading or settle — dropping it cost almost every offline reauth.
  `surface=sheet_reconnect`.
- **A return from Google's add-account flow reopens the PICKER once** (`auto: false`, never the sheet;
  `surface=button_after_add_account`). Credential Manager reports ONE string,
  `[16] User cancelled during add account flow and accounts were present`, whether the person added an
  account, backed out or was bounced — GMS's "verify it's you" BiometricPrompt was seen both cancelling
  itself and waiting for a finger, so a hands-off adb walk proves nothing. The result lands a beat before
  our resume, so the reopen waits `stallResumeGrace` for the foreground and never opens from behind another
  app.
- The offline hold (`sheet_after_offline`) and the lost-callback relaunch: [auth.md](auth.md) §Failure
  handling.

## What the screen may say about a failed attempt

**ONE line, the same for every failure — the retry line. No sentence under the pill, no link out of the
app** (owner: lines naming Play services or account settings were noise to an audience that cannot act
on them; all anyone can do is tap again). Never re-add a fix line or a help link. The held launch's wait
line is the one other subtitle — a state, never a failure. The classified outcome still rides
`AuthCancelled` into `login_cancelled` as `nudge` ([auth.md](auth.md) §Reading the failure buckets).

- **Everything but the wordmark comes from the ARBs, failure toasts included:** `authFailureText(kind)`,
  one key per `AuthFailureKind`. `AuthFailure.message` is English for logs only — a server failure's
  message is the Worker's text.
- **The type is a FIXED size on every phone and the LAYOUT absorbs a long translation** (owner: the way
  a shipped app does, never by resizing). The sizes are constants at the top of `sign_in_screen.dart`,
  set against Google's own sheet, which lands on this screen. The panel's 18 dp side padding may not
  grow: every dp leaves the pill's 180 dp slot.
- **The title is a button label and stays one line (`scaleDown`); the subtitle WRAPS and the pill
  grows** — at most two lines at text scale 1.0 and three at 1.3 on the covered phones, a fourth in the
  320 dp frame. Nothing truncates. `sign_in_size_matrix_test.dart` enforces it.
- **The pill is the ONLY tappable thing — never add a second control.** Google's sheet lands ON this
  screen, so anything else is reached by dismissing it first: a bottom-left language chip here pushed
  first-sheet sign-ins down, and its users made about twice the attempts and signed in far less.
  Settings is the one place language changes ([deep-links.md](deep-links.md) §Language precedence).
  The Terms · Privacy footer stays gone —
  Play's in-app policy requirement is met by Settings.
- The wordmark stays English and is the wall's only mark. **Icon glyphs take NO `shadows`:** Impeller
  paints a second mark beside a shadowed icon FONT; text shadows are fine.
