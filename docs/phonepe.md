# PhonePe v2 Autopay — hard-won facts

Read before touching `workers/src/lib/phonepe.ts`, `routes/payments.ts` or `cron/autopay-notify.ts`.
Every line was derived from a real failure; do NOT re-derive from the PhonePe docs, several of which
are wrong. Running on **PRODUCTION** credentials. Recurring debits have their own doc:
[autopay-debits.md](autopay-debits.md).

## Endpoints

1. **Mobile SDK setup token** = `POST /checkout/v2/sdk/order`, read the **top-level `token`**. NOT
   the web `/checkout/v2/pay` `redirectUrl` token.
2. **Cancel** — `/subscriptions/v2/{id}/cancel` first, `/checkout/v2/subscriptions/{id}/cancel` as
   fallback. The checkout variant 401'd on device back when it was the only path PhonePe documented;
   their docs list both now — keep this order regardless.
3. **Recurring** — `POST /subscriptions/v2/notify` → `POST /subscriptions/v2/redeem`; mandate status
   at `/subscriptions/v2/{id}/status?details=true`, order status at
   `/subscriptions/v2/order/{merchantOrderId}/status?details=true`.
4. **OAuth is `/v1/oauth/token`, and that is CORRECT on the v2 flow — do not "upgrade" it.** Sandbox
   `https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token`, production
   `https://api.phonepe.com/apis/identity-manager/v1/oauth/token`. "v2" names the product and the
   credential set — v2 onboarding issues v2 `client_id`/`client_secret`/`client_version`, which you
   POST to that v1 endpoint for a token sent as `Authorization: O-Bearer <token>`. There is no v2
   token endpoint to move to.

## The webhook

`Authorization: SHA256(username:password)`, deduped by **(event, orderId)** in KV with a 30-day TTL —
the event MUST be in the key. The order-id prefix is `DKS_`, which is how the shared merchant's
streams stay distinguishable from Pakiza's `PKZ_`. The registered URL is
`https://api.hsrutility.com/payments/webhook`, the hsr-cms dispatcher that forwards `DKS_` orders on.

**Order events nest the ids under `payload.paymentFlow`**; state-change events keep them top-level.
Read via `merchantSubscriptionIdOf()`. The flat read acked every real redemption webhook as "Missing
merchantSubscriptionId".

Intent-flow setups emit `subscription.setup.order.completed/failed`; the Worker aliases the
`checkout.order.*` names onto the same branches, so it is safe either way.

⚠ **No PhonePe webhook has ever been processed in production.** The `txn:` prefix in KV holds ZERO
keys for any event, including setup confirmations, while the server's own `ph:` marks sit in the
hundreds under the same 30-day TTL — so this is not a stale reading. **The cause is outside this
repo**: either the events are not ticked on the webhook in the PhonePe Business dashboard, or the
dispatcher is not forwarding `DKS_`. Until it is fixed the cron is the ONLY channel, and revoked or
paused mandates are invisible until a debit fails.

One webhook per MERCHANT, shared with Pakiza: Test-Mode, the selected events and the SHA password
apply to both, and the password is not editable after creation, so the Worker secrets must match it.
**Events are opt-in per webhook**, so a missing tick sends nothing and logs nothing.

## Mandate setup

**Direct UPI-intent flow (the frictionless path):** `POST /subscriptions/v2/setup` with
`paymentFlow.type: "SUBSCRIPTION_SETUP"` (NOT the checkout variant's `SUBSCRIPTION_CHECKOUT_SETUP`),
`paymentMode: {type:"UPI_INTENT", targetApp:"<android package>"}` plus `deviceContext.deviceOS`,
returning `{orderId, state, intentUrl}` — the app fires `intentUrl` at the chosen UPI app and the
user lands straight on its AutoPay sheet. Sandbox returns a `ppesim://` link, production
`upi://mandate`. No SDK, so the PR004/web-token trap class cannot occur here.

Initiate takes `targetApp` (opt-in, package-shape validated) and **MUST fall back to the SDK page
inside the SAME request on any intent failure** — a second initiate bounces off its own claim window.
Picker apps are a fixed allowlist, never an open `upi://` resolver query: a pay-only wallet accepts
the intent and then fails the mandate.

`trial_end` NULL → **PENNY_DROP** (₹2 — PhonePe requires exactly 200 paise for that flow — 1-day
trial). NOT NULL → `authWorkflowType: TRANSACTION` with a real ₹199 first debit (`amount: 19900`) →
straight to `active`. `maxAmount: 19900`, `amountType: FIXED`, `frequency: MONTHLY`.

`POST /payments/initiate` returns **409 `setup_in_progress`** when a setup is already in flight, kept
deliberately distinct from **409 `already_subscribed`** — the app treats `already_subscribed` as
success and must not do the same for an in-flight setup. Initiate is serialized on the user row, and
superseded mandates are revoked rather than orphaned.

The claim is released by the app calling **`POST /payments/abandon`** the moment the SDK returns
non-success: a user backing out and re-tapping must retry INSTANTLY. A lockout long enough to be
visible shipped once and users read it as "payments broken". The short claim window is only the
backstop for attempts that died without abandoning. The app rides out 409 `setup_in_progress`
silently with two retries, and **the pairing is load-bearing**: the sum of the client retry delays
equals the window, so a stale claim has always lapsed by the last retry and the message is
unreachable for a solo user, while a genuinely concurrent attempt still refuses. **Change either side
only with the other.**

**A failed setup RESTORES, never just expires.** A resubscribe claims the user's ONE subscriptions
row, so the claim rides over whatever entitlement that row still carried — and flipping every failed
setup to `expired` stripped a cancelled-but-live trial when the user backed out at the UPI app. All
three failure paths (abandon, the status FAILED/EXPIRED reconcile, the `*.order.failed` webhook)
write `CASE WHEN current_period_end > now() THEN 'cancelled' ELSE 'expired' END`, and the
setup-completed resurrect matches `('expired','cancelled')` for the same reason — a paid approval
racing the restore must still grant. `pending` with a live period keeps premium, so entitlement never
flickers while the sheet is open.

**Unpause must REARM the debit clock.** The cron's park nulls `next_debit_at`, so a status-only
unpause left a row neither cron pass could ever select: "Active" forever, never billed, premium
silently dead at period end. The `subscription.unpaused` webhook writes `next_debit_at =
COALESCE(next_debit_at, current_period_end)` and clears `notified_at`, scoped `AND status='paused'`
so a stray event cannot resurrect a cancelled or expired row. `/payments/status` heals BOTH lost
webhooks: mandate PAUSED while the row is trialing/active → park; mandate ACTIVE while the row is
paused → restore and rearm. Abandon checks the live order state first and answers `settled:true`
rather than expiring when PhonePe says COMPLETED, which would strand a paid mandate the webhook can
no longer grant.

Revoking a mandate the user never authorized answers **400 `SUBSCRIPTION_NOT_FOUND` from BOTH the
cancel and the status endpoint** — that is success (nothing exists, nothing can debit), not a live
orphan. `revokeMandateTolerant` must treat it so, or every abandoned setup logs a false "manual revoke
required" and buries the one alarm that matters.

A setup abandoned AT the sheet differs: the mandate reached `ACTIVATION_IN_PROGRESS`, cancel refuses,
the checkout-variant fallback 401s, and `revokeMandateTolerant` reads that state as still-live. The
abandon-path revoke discards that result, so the false "manual revoke required" fires on the user's
NEXT initiate. Do not chase it: no PIN was entered so nothing can debit, and PhonePe expires it
itself. Only the severity is wrong.

## Traps that return 200 while being broken

- **NEVER fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW. Scraping
  `?token=` out of `redirectUrl` yields a web-checkout token: the SDK answers PR004 "Unauthorized" on
  device while the Worker happily returns 200 — undebuggable from the server side.
- **`PHONEPE_ENV` is an exact string compare.** A trailing newline from a shell pipe silently routed
  production credentials to the SANDBOX host, whose reply is a 401 indistinguishable from bad
  credentials. `isProduction()` now trims and THROWS on anything but `PRODUCTION`/`SANDBOX`, and
  credentials and merchant id are trimmed too. Set secrets with `wrangler secret bulk <json>`, never
  a shell pipe.
- **Flipping `PHONEPE_ENV` does NOT invalidate the cached OAuth token** (KV `phonepe:oauth` — one
  constant key, no env component). Delete it after any env or credential change, or the old token
  replays against the new host.
- **Symptom map:** PR004/Unauthorized on device = a bad `merchantId` or a web token; the Worker
  validates neither, only echoes them, so it still returns 200. `OAuth 401` in the tail = the wrong
  host or a whitespace-polluted credential.

## Recovery paths that are load-bearing

- **A lost SDK callback does not lose the payment.** `POST /payments/status` reconciles the row
  against PhonePe. A device run ended with their webview stuck on "confirming payment" while the
  mandate was COMPLETED at their end; status-reconcile is what saved it. Do not remove it.
- **The confirmation poll must TOLERATE network failure.** The app is backgrounded behind the UPI
  app, so a `SocketException: Failed host lookup` mid-poll is normal, not terminal. Rethrowing it
  abandoned the budget, showed a generic error and nulled the order id so the resume checkpoint
  bailed too — a settled mandate with nobody watching. Never reached the server → say confirmation is
  late, never the refund line. The poll also OUTLIVES the paywall, so every state and ref write sits
  behind a mounted check, and the zombie and the late catch-up share ONE marker so an order is never
  counted twice.
- **`phonepe_subscription_id` may stay NULL** when the webhook is lost and only status-reconcile
  runs. Harmless: the cron addresses PhonePe by *our* `merchant_subscription_id`.

The billing lifecycle has been proven against UAT plus a local stub — re-prove after a change with
`.claude/skills/verify-payments/` rather than re-deriving.
