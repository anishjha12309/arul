# PhonePe v2 Autopay — the Worker side

Read before touching `workers/src/lib/phonepe.ts` or `workers/src/routes/payments.ts`. Every line came
from a real failure and several PhonePe doc pages are wrong, so never re-derive from the docs. The
Worker runs on **PRODUCTION** credentials. Recurring debits: [autopay-debits.md](autopay-debits.md) ·
webhook: [phonepe-webhook.md](phonepe-webhook.md) · the app's picker, QR, resume and poll:
[checkout.md](checkout.md) · the ₹99 switch: [cancel-offer.md](cancel-offer.md).

## Endpoints

1. **Mobile SDK setup token** = `POST /checkout/v2/sdk/order`, read the **top-level `token`** — NOT the
   web `/checkout/v2/pay` `redirectUrl` token.
2. **Cancel** — `/subscriptions/v2/{id}/cancel` first, `/checkout/v2/subscriptions/{id}/cancel` as the
   fallback. The checkout variant 401'd on device; keep this order whatever the docs list.
3. **Recurring** — `POST /subscriptions/v2/notify` → `POST /subscriptions/v2/redeem`; mandate status
   `/subscriptions/v2/{id}/status?details=true`, order status
   `/subscriptions/v2/order/{merchantOrderId}/status?details=true`.
4. **OAuth is `/v1/oauth/token`, and that is CORRECT on the v2 flow — never "upgrade" it.** Sandbox
   `https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token`, production
   `https://api.phonepe.com/apis/identity-manager/v1/oauth/token`. "v2" names the product and the
   credential set (`client_id`/`client_secret`/`client_version`); the token goes out as
   `Authorization: O-Bearer <token>`. There is no v2 token endpoint.

## Two merchants — the mandate id picks the keys

A mandate lives under the merchant that created it, and the other merchant's keys answer
`SUBSCRIPTION_NOT_FOUND`: Pass A parks that row `cancelled`, `revokeMandateTolerant` calls a live
mandate revoked. So every call routes by `merchantOf(id)` (`lib/phonepe.ts`): `DKS_H…` = HSRUTILITYONLINE
(`PHONEPE_HSR_*`), anything else = AUTOGRAMAPPSONLINE (`PHONEPE_*`), forever. Not a column — five
statements swap ids between `merchant_subscription_id` and `superseded_mandate_id`.

- Redemption and refund ids inherit their mandate's (original order's) marker; a call whose ids name
  two merchants throws before PhonePe is reached.
- `PHONEPE_SETUP_MERCHANT` ([vars]: `legacy` | `hsr-internal` | `hsr`) steers NEW setups only; initiate
  returns the owning merchant's `merchantId` for the SDK. Missing hsr keys keep setups on legacy and
  make hsr calls a transient error — retried, never parked.
- Legacy keys stay live while any legacy mandate does (active rows renew with no end). Once an hsr
  mandate exists, never roll back past the dual-merchant Worker: the old code parks every `DKS_H` row.

## Mandate setup

**Direct UPI intent:** `POST /subscriptions/v2/setup` with `paymentFlow.type: "SUBSCRIPTION_SETUP"`
(NOT the checkout variant's `SUBSCRIPTION_CHECKOUT_SETUP`), `paymentMode: {type:"UPI_INTENT",
targetApp:"<android package>"}` and `deviceContext.deviceOS`, returning `{orderId, state, intentUrl}`.
Sandbox answers a `ppesim://` link, production `upi://mandate`. No SDK, so the PR004 web-token trap
cannot occur on this path.

Initiate takes `targetApp` (opt-in, package-shape validated) and **MUST fall back to the SDK page inside
the SAME request on any intent failure** — a second initiate bounces off its own claim window. The
`targetApp == null` branch stays for fielded builds.

`sdk/order` MUST send `subscriptionDetails.expireAt` (29 years; PhonePe caps it at 30): omitted, the SDK
payment page reads "auto-paid till NaNth Invalid Date". The intent flow defaults to 30 years.

`trial_end` NULL → **PENNY_DROP** (₹2 — PhonePe requires exactly 200 paise for that flow — and a 1-day
trial). NOT NULL → `authWorkflowType: TRANSACTION` with a real ₹199 first debit (`amount: 19900`) →
straight to `active`. `maxAmount` = the claim's `price_paise`, `amountType: FIXED`, `frequency: MONTHLY`.

**409 `setup_in_progress` stays distinct from 409 `already_subscribed`** — the app treats
`already_subscribed` as success and must never do that for an in-flight setup. Initiate is serialized
on the user row. `POST /payments/abandon` releases the claim the moment the SDK returns non-success; the
short claim window only backstops attempts that died without abandoning. The client's retry delays are
paired with that window ([checkout.md](checkout.md)) — change either side only with the other.

## A re-subscribe PARKS the mandate it replaces

A lapsed trial whose ₹199 is failing (Z9) still has a live mandate climbing the dunning ladder, and its
owner is exactly who re-taps Subscribe. Revoking it at initiate killed mandates that would have paid on a
later rung while the replacement setups mostly went unapproved. So initiate over a
`trialing`/`active`/`paused` row writes the old id (and its price) to `superseded_*` and touches nothing at
PhonePe; only a `pending` or `expired` row's mandate (never approved, or ladder exhausted) is revoked on
the spot. Two mandates on one user is safe: only `merchant_subscription_id` is ever notified or redeemed.

The parked id is revoked by the grant (setup-completed webhook, status COMPLETED reconcile — self-joined
so the PRIOR value rides back, revoke off the response path), restored by every failure path, made live
again by a redemption webhook that names it (the unapproved newer id is then revoked), and revoked with
the live one by `/payments/cancel` and account deletion. A `subscription.revoked` for a parked id just
clears the column.

## A failed setup RESTORES, never just expires

A resubscribe claims the user's ONE row, so the claim rides over whatever entitlement it carried —
expiring every failed setup stripped a cancelled-but-live trial when the user backed out at the UPI app.
Every failure path (abandon, the status FAILED/EXPIRED reconcile, the `*.order.failed` webhook, the claim
sweep, a revoke of the claim's own id while one is parked) runs ONE `releaseClaim`: a parked
`superseded_mandate_id` wins and becomes `merchant_subscription_id` again at its own price,
`active` when `current_period_end > trial_end` else `trialing` (the claim never touches ladder columns,
so the cron resumes where it stood); otherwise `current_period_end > now()` → `cancelled`, else
`expired`. The setup-completed resurrect matches `('expired','cancelled')` so a paid approval racing the
restore still grants. `pending` with a live period keeps premium, so entitlement never flickers while
the sheet is open.

## Healing what the webhook never reported

Only the hsr merchant's webhook delivers; the legacy one never has, so every heal below stays a PULL.

- **`POST /payments/status` reconciles the row against PhonePe** — a lost SDK callback never loses the
  payment. A device run ended with PhonePe's webview stuck on "confirming" while the mandate was
  COMPLETED; status-reconcile saved it.
- **A settled debit on a row outside the cron's reach** is healed by ONE `healSettledDebit` — status, the
  hourly sweep, and initiate before it claims ([autopay-debits.md](autopay-debits.md) §The hourly sweeps).
  The redemption webhook grants only when the ROOT `payload.state` is COMPLETED — the transaction-level
  event carries a PENDING order.
- **Unpause must REARM the debit clock.** The cron's park nulls `next_debit_at`, so a status-only unpause
  left a row neither pass could select: "Active" forever, never billed. The rearm writes
  `next_debit_at = COALESCE(next_debit_at, current_period_end)`, clears `notified_at`, scoped
  `AND status='paused'` so a stray event cannot resurrect a cancelled or expired row. It restores `trialing`
  unless converted (`current_period_end > trial_end`), like every other writer: a date rule relabelled
  never-converted trials `active`, and their first ₹199 skipped the first-conversion report. ONE home,
  `lib/subscription-rearm.ts`, shared by the webhook, the cron's Pass D ([cron.md](cron.md)) and status
  (mandate PAUSED on a live row → park; mandate ACTIVE on a paused row → restore and rearm).
- Abandon reads the live order first and answers `settled:true` on COMPLETED rather than expiring a paid
  mandate the webhook can no longer grant.
- `phonepe_subscription_id` may stay NULL when only status-reconcile ran. Harmless: the cron addresses
  PhonePe by OUR `merchant_subscription_id`.

## Revoking a mandate nobody approved

It answers **400 `SUBSCRIPTION_NOT_FOUND` from BOTH cancel and status** — success (nothing can debit),
not a live orphan. `revokeMandateTolerant` must read it so, or every abandoned setup logs a false
"manual revoke required" and buries the one alarm that matters. A setup abandoned AT the sheet sits in
`ACTIVATION_IN_PROGRESS`: cancel refuses, the fallback 401s and the false alarm fires on the user's NEXT
initiate. Do not chase it — no PIN was entered and PhonePe expires it itself.

## Traps that return 200 while broken

- **NEVER fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW. A `?token=`
  scraped from `redirectUrl` is a web-checkout token: the SDK answers PR004 "Unauthorized" on device
  while the Worker returns 200.
- **`PHONEPE_ENV` is an exact string compare.** A trailing newline from a shell pipe once routed
  production credentials to the SANDBOX host as a 401 indistinguishable from bad credentials.
  `isProduction()` trims and THROWS on anything but `PRODUCTION`/`SANDBOX`, and credentials and
  merchant id are trimmed; every other secret is not — set them with `wrangler secret bulk`.
- **The cached OAuth token survives every switch** (KV `phonepe:oauth` legacy, `phonepe:oauth:hsr`; no
  env component) — env, credential, host, or a local stub. Delete both after any of them, or the old
  token replays.
- **Symptom map:** PR004/Unauthorized on device = a bad `merchantId` or a web token (the Worker only
  echoes them, so still 200). `OAuth 401` in the tail = the wrong host or a whitespace-polluted
  credential.

Re-prove the billing lifecycle after a change with `.claude/skills/verify-payments/`, never by
re-deriving.
