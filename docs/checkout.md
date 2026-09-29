# Checkout — the app side of a UPI Autopay setup

Read before touching `lib/features/premium/**` (the purchase notifier, the UPI picker, the QR, the
return page). The Worker contract it drives: [phonepe.md](phonepe.md).

## Which apps the picker offers

- **Two gates, both required:** `MANDATE_APPS`, never an open `upi://` query — a pay-only wallet accepts
  the intent and then fails the mandate — AND the device resolver against a mandate-SHAPED probe URL,
  which separates the two (Mobikwik answers `upi://pay` only; Paytm uses a different activity for each).
- `MANDATE_APPS` IS PhonePe's published mandate set (PhonePe, BHIM, GPay, Paytm, CRED, Amazon Pay,
  SuperMoney) plus the sandbox simulator. PhonePe's docs print no Android package, so each id comes
  from that vendor's Play listing. Nothing else joins without ONE real ₹2 penny drop. The last three sit
  at the TAIL by the owner's call — added without moving the default or the ranked four.
- **Never reorder it off observed completion rates** — they are self-selected by the position the app
  already holds (an app reached by scrolling past the top two selects for determined payers). A reorder
  needs a split test.
- **No hosted-page fallback** — it almost never completed, and a route that cannot finish is worse than
  none.

## The QR

- On a phone with no offered app **the CTA itself opens an on-screen QR** of the SAME `intentUrl` — it
  carries no app binding (`targetApp` only steers what we LAUNCH), so any UPI app on a second phone
  scans and approves it. No install prompt and no second line (owner): that phone has one way to pay,
  and store links asked someone mid-checkout to go and fetch a payment app.
- It is ALSO the picker's last row wherever apps exist, as a ONE-TIME route: the sheet pops the
  `kUpiPickQr` sentinel in place of a package and nothing reaches `arul_upi_app`, or a curious tap would
  leave the CTA launching an app nobody chose.
- Over an open order it abandons like an app switch, and `switchApp`'s same-app guard MUST skip it —
  the QR names `com.phonepe.app` as a formality and would read as "the app you already picked".
- Pass `mode: "qr"` on initiate, or the order files under `com.phonepe.app` and mandates PhonePe never
  saw pollute the column that ranks apps by completions. A QR request the Worker answers with the SDK
  page is a dead end (that page needs an app on THIS phone), so the app abandons instead.

## The claim and the retries

The user backing out at the SDK calls `POST /payments/abandon` at once, so a re-tap retries INSTANTLY —
a visible lockout shipped once and read as "payments broken". The app rides out 409
`setup_in_progress` silently with two retries whose delays SUM to the Worker's claim window, so a stale
claim has lapsed by the last retry while a genuinely concurrent attempt still refuses. **Change either
side only with the other.** A LINK failure on initiate (DNS miss, the 12 s timeout) retries under the
spinner — 3 attempts, 15 s cap — inside that same loop; a server ANSWER is never retried.

## The return from the UPI app

- **An OPEN order on return is RESUMABLE, never a failure.** Most failed setups are `INTENT_EXPIRED` —
  the sheet was reached and not approved — and abandoning on that return revoked a mandate the person
  could still approve. `PurchaseResumable` keeps the SAME link, app and order: "open again" re-fires it
  (no initiate, no second `checkout_started`) and a slow status watch lets a late approval land.
- **No "start over" button and no failure toast here** (owner: the users are not technical, and "any
  amount deducted will be refunded" is false when nothing was approved). The deadline passing, or
  PhonePe reporting the order expired, resets the CTA SILENTLY; the next tap is a fresh order.
- **The app chip stays changeable:** another app abandons the open order and starts a fresh checkout
  with it in one motion; the same app does nothing.
- **Deadline = the link's `QRexpire`**, split from the RAW query then percent-decoded
  (`Uri.queryParameters` turns the bare `+05:30` into a space). Production links expire 5 min after
  creation, whatever the docs' sample says; with no `QRexpire`, launch + 10 min, capped at 15 — the setup
  response carries no expiry. The QR shares that deadline: a client window shorter than PhonePe's would
  call a live code expired and let a late scan set up a mandate the UI had given up on.
- **On the TRIAL sell every unapproved return pushes the return page** — never on the ₹199 sell, never
  stacked. Its button keeps the resume/switch/QR rules. It BORROWS the paywall's one audible player and
  hands it back only after its exit plus a frame ([video-feed.md](video-feed.md)).
  `feature_flags.return_video.enabled: false` restores the plain resumable paywall.

## The confirmation poll

It must TOLERATE network failure: the app sits behind the UPI app, so a `Failed host lookup` mid-poll is
normal. Rethrowing it once abandoned the budget, nulled the order id and left a settled mandate with
nobody watching. Never reached the server → say confirmation is late, never the refund line. The poll
OUTLIVES the paywall, so every state and ref write sits behind a mounted check, and the zombie poll and
the late catch-up share ONE marker so an order is never counted twice.

- `/payments/status` answers for the user's ONE row, never the polled order: a zombie poll hears a
  LATER tap's grant, so the conversion takes the row's `merchant_order_id`, never the poll's own.
- A failed re-setup hands the row back to its parked mandate — `trialing`, a trial that ended days
  ago, under the FAILED order's id. Both emitters count `trial_started` only while `trial_end` is
  ahead (`isRunningTrial`); a handed-back row is marked reported, never fired.

## The unfinished-trial marker

A TRIAL setup (never a spent-trial ₹199 one) is marked AT THE UPI HANDOFF, not at a failure — a large
share of CTA taps die with no terminal event (the process killed behind the UPI app, the paywall popped
while resumable). It drives one dismissible feed row and one reminder
([notifications.md](notifications.md)); any premium read or settled purchase clears both.

## Events (GA4-only; the rest: [analytics-events.md](analytics-events.md))

- `paywall_shown` reports the sell ONCE the installed-app probe has ANSWERED — the first build would
  stamp `has_upi_app: no` on everyone. **GA4-only**, pinned off the PostHog list. `upi_apps` are short
  codes **sorted** (the picker floats the remembered app, so picker order would split one set into
  rotations); `upi_others` are the mandate handlers the allowlist REFUSES, as raw package names packed
  to whole entries inside 100 chars, `upi_other_count` surviving truncation. `variant`
  (`trial`|`paid`|`resubscribe`|`unknown`) and `paywall_source` — GA4 owns the bare `source`. **Every
  value is a string**: GA4 parses no numeric parameter into an event-scoped dimension on app streams.
- `payment_failed` covers EVERY terminal exit through one `_fail()`. **`reason` is a short stable code,
  NEVER the user-facing copy.** `network_error` = a dead initiate link after retries; `unexpected_error`
  = a genuine defect, also sent to Crashlytics. A resumable intent that ends unapproved says
  `intent_app_switched` or `intent_resume_expired` (a PhonePe verdict stays `expired`) — silent on
  screen.
