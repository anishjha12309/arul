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
- **A resume re-polls the SAME order id**, so only the newest attempt may clear it: the replaced poll's
  wake-up cleared it once and the next return was a no-op (~2 min spinner). A status answer landing after a
  resume, switch or deadline decides nothing.
- A resubscribe claim the Worker released answers `cancelled`, not `expired` (its period is live): it ends
  the attempt like `expired` (`claim_released`), never a dead "open again".
- **A premium `pending` row is a claim over a paid period**: /premium and the help sheet show the plan it
  left (`shownStatus`; `offer_switch` tells a switch from a ₹99 winback), never the sell page.
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

## The cancel offer ([cancel-offer.md](cancel-offer.md))

- **Offer first, then confirm.** Cancel subscription opens the offer sheet when `/me` says eligible, else the
  "Cancel subscription?" confirm. Every way off the sheet (X, "I don't want the offer", back, drag, scrim) opens
  that confirm: a decline never cancels by itself. Only its "Cancel it" posts `/payments/cancel`; "Keep
  premium" keeps the plan. The retry sheet's cancel goes through the same confirm.
- **A returning user's paid checkout opens the same sheet** (`winback_offer_eligible`): Resubscribe, the paid
  sell and the picker's QR row all pass `_startPaid`. Accept = `winback_99` through the app or QR tapped, an
  ordinary ₹99 sale (resumable, converts); the link = full price; X/back start nothing.
- **The 10-minute hold is real, per sheet** (owner): "Offer ends in mm:ss" from 10:00; at 00:00 Get discount
  disables and the sheet says the offer expired, cancel and close still work; the next Cancel tap shows a fresh
  10:00. True for every visit on purpose: a countdown that lies is "false urgency" under India's CCPA dark-pattern
  guidelines. The server never enforces it — the row stays eligible, so an accept at 00:01 must not bounce.
- An offer attempt (`offer: 'cancel_99'` on initiate) is a switch, never a sale: no `trial_started`, no
  trial marker, no return page, and `TrialConversionCatchUp` treats a 9900 row as already reported.
- **Never resumable.** An open order on return is abandoned (the ₹199 comes back at once) and the retry
  sheet shows: a user who said "cancel" must not silently stay on ₹199, and a failed attempt must not
  cancel anything without a tap. Its back and scrim change nothing.
- The outcome is `/payments/status`'s `price_paise`: trialing/active at 9900 = switched, at 19900 = released.
  A poll that never reached the server toasts instead of the retry sheet — the switch may still land, and a
  retry would start a second one. Never the refund line: nothing was debited but the ₹2 check.

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
