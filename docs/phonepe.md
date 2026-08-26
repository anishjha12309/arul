# PhonePe v2 Autopay — hard-won facts

Read this before touching `workers/src/lib/phonepe.ts`, `routes/payments.ts` or
`cron/autopay-notify.ts`. Every line below was derived from a real failure; do NOT re-derive from the
PhonePe docs, several of which are wrong. Running on **PRODUCTION** credentials.

## Endpoints

1. **Mobile SDK setup token** = `POST /checkout/v2/sdk/order`, read the **top-level `token`**. NOT the
   web `/checkout/v2/pay` `redirectUrl` token.
2. **Cancel** — `/subscriptions/v2/{id}/cancel` first; `/checkout/v2/subscriptions/{id}/cancel` kept
   as fallback. The checkout-variant 401'd on device back when it was the only path PhonePe
   documented; their docs now list both (2026-08-14) — keep the order above regardless.
3. **Recurring** — `POST /subscriptions/v2/notify` → `POST /subscriptions/v2/redeem`; status at
   `/subscriptions/v2/{id}/status?details=true`.
4. **OAuth token is `/v1/oauth/token`, and that is CORRECT on the v2 flow — do not "upgrade" it.**
   Verified against PhonePe's Authorization reference 2026-07-29: sandbox
   `https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token`, production
   `https://api.phonepe.com/apis/identity-manager/v1/oauth/token`. "v2" names the product/API version
   and the credential set — v2 onboarding issues v2 `client_id`/`client_secret`/`client_version`,
   which you POST to that v1 endpoint for a token sent as `Authorization: O-Bearer <token>`. There is
   no v2 token endpoint to move to.
5. **Webhook** — `Authorization: SHA256(username:password)`, deduped by (event, orderId) in KV (30 d
   TTL). **Intent-flow setups emit `subscription.setup.order.completed/failed`, NOT
   `checkout.order.*`** — handled as aliases of the same branches; the Business-dashboard webhook
   must have the `subscription.setup.order.*` events SELECTED or PhonePe never sends them (grant
   then waits for the app's status poll / paywall self-heal).
   Order-id prefix is `DKS_`, which is how the shared merchant's streams stay distinguishable from
   Pakiza's `PKZ_`. The registered URL is `https://api.hsrutility.com/payments/webhook` — the hsr-cms
   dispatcher, which forwards `DKS_` orders to arul-api.
   **Order events nest the ids under `payload.paymentFlow`** (state-change events keep them top-level —
   PhonePe webhook reference, field table); read via `merchantSubscriptionIdOf()`. The flat read acked
   every real redemption webhook as "Missing merchantSubscriptionId" (0 `txn:*` marks ever, 2026-08-25).
   One webhook per MERCHANT, shared with Pakiza: Test-Mode, events and the SHA password apply to both;
   the password is not editable after creation — the Worker secrets must match it.
   Proven 2026-08-25 13:00 IST: a redemption settled (order COMPLETED) and the dispatcher logged ZERO
   deliveries in the following 3 min while serving other traffic — PhonePe is not sending; fix is in the
   Business dashboard (Test-Mode OFF, Redemption + Setup events ticked), not in code.

## Mandate setup

**Direct UPI-intent flow (the frictionless path):** `POST /subscriptions/v2/setup` with
`paymentFlow.type: "SUBSCRIPTION_SETUP"` (NOT the checkout variant's `SUBSCRIPTION_CHECKOUT_SETUP`),
`paymentMode: {type:"UPI_INTENT", targetApp:"<android package>"}` + `deviceContext.deviceOS` returns
`{orderId, state, intentUrl}` — the app fires intentUrl at the chosen UPI app and the user lands
straight on its AutoPay sheet. Proved on prod 2026-08-11 through the deployed worker. Sandbox
returns a `ppesim://` link (PhonePe simulator app), prod `upi://mandate`. No SDK, so the PR004/web-
token trap class cannot occur here; order status is the same `/subscriptions/v2/order/{id}/status`
family. Initiate takes `targetApp` (opt-in, package-shape validated) and MUST fall back to the SDK
page inside the SAME request on any intent failure — a second initiate bounces off its own claim
window. Picker apps are a fixed allowlist (PhonePe's mandate-capable list), never an open `upi://`
resolver query: a pay-only wallet accepts the intent and then fails the mandate.

`trial_end` NULL → **PENNY_DROP** (₹2, 1-day trial). NOT NULL → `authWorkflowType: TRANSACTION` with a
real ₹199 first debit (`amount: 19900`) → straight to `active`. `maxAmount: 19900`,
`amountType: FIXED`.

`POST /payments/initiate` returns **409 `setup_in_progress`** when a setup is already in flight, kept
deliberately distinct from **409 `already_subscribed`** — the app treats `already_subscribed` as
success and must not do the same for an in-flight setup. Initiate is serialized on the user row;
superseded mandates are revoked rather than orphaned. The claim is released by the app calling
**`POST /payments/abandon`** the moment the SDK returns non-success (a user backing out then
re-tapping must retry INSTANTLY, not wait out a window — the 90s version of this lockout shipped and
users read it as "payments broken"); the 4s claim window is only the backstop for attempts that died
without abandoning (app killed at the sheet). The app rides out 409 `setup_in_progress` silently
(`_initiateWithRetry`, 2×2s) — a rapid re-tap racing its own abandon surfaced "please wait" to a
human twice (device, 2026-08-12). The pairing is load-bearing: sum(client retry delays) ≥ window, so
a stale claim has always lapsed by the last retry and the message is unreachable for a solo user;
only a genuinely concurrent attempt still refuses. Change either side only with the other.

**A failed setup RESTORES, never just expires.** A resubscribe claims the user's ONE subscriptions
row, so the claim rides over whatever entitlement the row still carried — and flipping every failed
setup to `expired` stripped a cancelled-but-live trial when the user backed out at the UPI app
(device, 2026-08-12). All three failure paths (abandon, the status FAILED/EXPIRED reconcile, the
`*.order.failed` webhook) now write `CASE WHEN current_period_end > now() THEN 'cancelled' ELSE
'expired' END`; the setup-completed resurrect matches `('expired','cancelled')` for the same reason
— a paid approval racing the restore must still grant. `pending` with a live period keeps premium
(entitlement.ts), so the entitlement never even flickers while the sheet is open.

**Unpause must REARM the debit clock.** The cron's park nulls `next_debit_at`, so a status-only
unpause left a row neither cron pass could ever select: "Active" forever, never billed, premium
silently dead at period end (the zombie, 2026-08-13). The `subscription.unpaused` webhook writes
`next_debit_at = COALESCE(next_debit_at, current_period_end)` + `notified_at = NULL`, and is scoped
`AND status='paused'` so a stray event can never resurrect a cancelled/expired row. `/payments/status`
heals BOTH lost webhooks: mandate PAUSED while row trialing/active → park; mandate ACTIVE while row
paused → restore + rearm. Abandon checks the live order state first and
answers `settled:true` instead of expiring when PhonePe says COMPLETED — expiring there would strand
a paid mandate the webhook can no longer grant (its UPDATE is scoped `AND status='pending'`).

Revoking a mandate the user never authorized answers **400 `SUBSCRIPTION_NOT_FOUND` from BOTH the
cancel and the status endpoint** — that is success (nothing exists, nothing can debit), not a live
orphan. `revokeMandateTolerant` must treat it so, or every abandoned setup logs a false "manual
revoke required" and buries the one alarm that matters (seen live 2026-08-11).

A setup abandoned AT the sheet differs: the mandate reached `ACTIVATION_IN_PROGRESS`, so cancel
answers **400 `INVALID_SUBSCRIPTION_STATE`** and the checkout-variant fallback 401s, and
`revokeMandateTolerant` reads that state as still-live. The abandon-path revoke discards that
result, so the false "manual revoke required" `console.error` fires on the user's NEXT initiate
(the supersede revoke), not at the abandon itself. Do not chase it: no PIN was entered so nothing
can debit, and PhonePe expires it itself (`EXPIRED` is terminal; we send no `expireAt`, so their
default applies). Only the severity is wrong (device, 2026-08-14).

## Traps that return 200 while being broken

- **NEVER fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW. Scraping
  `?token=` out of `redirectUrl` yields a web-checkout token: the SDK answers PR004 "Unauthorized" on
  device while the Worker happily returns 200 — undebuggable from the server side.
- **`PHONEPE_ENV` is an exact string compare.** A trailing newline (`"PRODUCTION" | wrangler secret
  put`) silently routed prod credentials to the SANDBOX host, whose reply is `401 {"code":"401"}` —
  indistinguishable from bad credentials. `isProduction()` now trims and THROWS on anything but
  `PRODUCTION`/`SANDBOX`; credentials and merchant id are trimmed too. Set secrets with
  `wrangler secret bulk <json>`, never a shell pipe.
- **Flipping `PHONEPE_ENV` does NOT invalidate the cached OAuth token** (KV `phonepe:oauth`). Delete
  that key after any env or credential change, or the old token is replayed against the new host.
- **Symptom map:** PR004/Unauthorized on device = bad `merchantId` or a web token (the Worker
  validates neither — it only echoes them, so it still returns 200). `OAuth 401` in the tail = wrong
  host or a whitespace-polluted credential.

## Recovery paths that are load-bearing

- **A lost SDK callback does not lose the payment.** `POST /payments/status` reconciles the row
  against PhonePe. A real device run ended with PhonePe's webview stuck on "confirming payment"
  while the mandate was `COMPLETED` at their end; status-reconcile is what saved it. Do not remove it.
- **Recurring debits have their own doc** — [autopay-debits.md](autopay-debits.md). Read it before
  touching `cron/autopay-notify.ts`: redeem error codes, order states, and why order status (never
  the redeem response) decides whether money moved.
- **`phonepe_subscription_id` may stay NULL** when the webhook is lost and only status-reconcile runs.
  Harmless: the cron addresses PhonePe by *our* `merchant_subscription_id`.
- Dunning: retries 1–4 stay alive, the subscription **expires at retry 5** and is then ignored.

The billing lifecycle has been proven end-to-end against UAT + a local stub — re-prove after a
change with `.claude/skills/verify-payments/` (its reference.md holds the known-good baseline).
