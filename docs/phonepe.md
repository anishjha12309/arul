# PhonePe v2 Autopay — hard-won facts

Read this before touching `workers/src/lib/phonepe.ts`, `routes/payments.ts` or
`cron/autopay-notify.ts`. Every line below was derived from a real failure; do NOT re-derive from the
PhonePe docs, several of which are wrong. Running on **PRODUCTION** credentials.

## Endpoints

1. **Mobile SDK setup token** = `POST /checkout/v2/sdk/order`, read the **top-level `token`**. NOT the
   web `/checkout/v2/pay` `redirectUrl` token.
2. **Cancel** — the documented `/checkout/v2/subscriptions/{id}/cancel` 401s. The WORKING path is
   `/subscriptions/v2/{id}/cancel` (try it first; documented path kept as fallback).
3. **Recurring** — `POST /subscriptions/v2/notify` → `POST /subscriptions/v2/redeem`; status at
   `/subscriptions/v2/{id}/status?details=true`.
4. **OAuth token is `/v1/oauth/token`, and that is CORRECT on the v2 flow — do not "upgrade" it.**
   Verified against PhonePe's Authorization reference 2026-07-29: sandbox
   `https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token`, production
   `https://api.phonepe.com/apis/identity-manager/v1/oauth/token`. "v2" names the product/API version
   and the credential set — v2 onboarding issues v2 `client_id`/`client_secret`/`client_version`,
   which you POST to that v1 endpoint for a token sent as `Authorization: O-Bearer <token>`. There is
   no v2 token endpoint to move to.
5. **Webhook** — `Authorization: SHA256(username:password)`, deduped by orderId in KV (30 d TTL).
   Order-id prefix is `DKS_`, which is how the shared merchant's streams stay distinguishable from
   Pakiza's `PKZ_`. The registered URL is `https://api.hsrutility.com/payments/webhook` — the hsr-cms
   dispatcher, which forwards `DKS_` orders to arul-api.

## Mandate setup

`trial_end` NULL → **PENNY_DROP** (₹2, 1-day trial). NOT NULL → `authWorkflowType: TRANSACTION` with a
real ₹199 first debit (`amount: 19900`) → straight to `active`. `maxAmount: 19900`,
`amountType: FIXED`.

`POST /payments/initiate` returns **409 `setup_in_progress`** when a setup is already in flight, kept
deliberately distinct from **409 `already_subscribed`** — the app treats `already_subscribed` as
success and must not do the same for an in-flight setup. Initiate is serialized on the user row;
superseded mandates are revoked rather than orphaned.

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
- **Stuck-`PENDING` debits converge** — autopay Pass C reconciles via `getOrderStatus` once a debit is
  more than 2 h overdue.
- **`phonepe_subscription_id` may stay NULL** when the webhook is lost and only status-reconcile runs.
  Harmless: the cron addresses PhonePe by *our* `merchant_subscription_id`.
- Dunning: retries 1–4 stay alive, the subscription **expires at retry 5** and is then ignored.

What has already been proven end-to-end, so you need not re-test it:
[billing-verified.md](billing-verified.md). To re-prove it after a change:
`.claude/skills/verify-payments/`.
