# The PhonePe webhook — and why it has never fired

Read before touching webhook handling in `workers/src/routes/payments.ts`. Endpoints, setup, the two
merchants and the heal paths: [phonepe.md](phonepe.md) · recurring debits: [autopay-debits.md](autopay-debits.md).

**No AUTOGRAMAPPSONLINE (legacy) webhook has ever been processed in production** — the KV `txn:` prefix
held no key for any event while the server's own `ph:` marks under the same TTL sat in the hundreds. The
cron is the only channel that has ever worked there, so a revoked or paused legacy mandate stays
invisible until a debit fails. Never let the webhook become the only path to a correct row.

## Two webhooks, one handler

- **Legacy** (AUTOGRAMAPPSONLINE): `https://api.hsrutility.com/payments/webhook`, the hsr-cms dispatcher,
  which forwards `DKS_` orders here. Shared with Pakiza (`PKZ_`), so Test Mode, the ticked events and
  the SHA password apply to both apps. Pair: `PHONEPE_WEBHOOK_USERNAME/PASSWORD`.
- **HSRUTILITYONLINE** (hsr): `https://arul-api.hsrutility.com/payments/webhook`, direct. Pair:
  `PHONEPE_HSR_WEBHOOK_USERNAME/PASSWORD`. Subscription and checkout events only; refund, dispute,
  settlement and notification events are deliberately not ticked.
- A dashboard password cannot be edited after creation — the Worker secrets must match it. The dashboard also
  offers **HMAC** auth (`x-phonepe-checksum-key-id` / `-signature` headers); the handler verifies SHA only, so
  an HMAC webhook would be refused 401 on every delivery.
- Either pair authenticates (constant-time compare); the id's marker, never the pair, picks the merchant.
  An order event whose `payload.merchantId` is the OTHER merchant's, or whose order and mandate ids carry
  different markers, is refused and left unmarked; an unfamiliar `merchantId` is processed by the id.

## The contract

- `Authorization: SHA256(username:password)`. ORDER events dedupe by **(event, orderId)** in KV with a
  30-day TTL — the event MUST be in the key, or a later event for the same order is dropped.
- **State events carry no order id** — `subscription.paused/unpaused/revoked/cancelled` hold only the
  mandate ids, `state` and the pause window. Keyed on the order id, every revoke was acked as "Missing
  orderId" and dropped, and UPI-app revokes are most trial cancels. They key on (event, mandate id,
  state, `pauseStartDate`); an unpause has null pause dates, so it is never deduped — its rearm is
  scoped to `paused` rows.
- **Order events nest the ids under `payload.paymentFlow`**; state-change events keep them top-level.
  Read through `merchantSubscriptionIdOf()` — the flat read acked every real redemption webhook as
  "Missing merchantSubscriptionId".
- Intent-flow setups emit `subscription.setup.order.completed/failed`; the Worker aliases the
  `checkout.order.*` names onto the same branches.
- PostHog captures run in `waitUntil`, after the 200 — an analytics round-trip never holds PhonePe's
  acknowledgement back. DB writes stay awaited: the `txn:` mark is written only after them.

## Where the legacy one dies: PhonePe is not sending

Proven by synthetic POSTs to the live URL: the dashboard credentials pass this handler's SHA-256 check
through the hsr-cms relay (`200 ok` on a `DKS_` id matching no row; a wrong password gets
`401 invalid_signature`), so credentials, `DKS_` routing and this handler are correct. The zone's
Security Events for `/payments/webhook` show only the team's own test POSTs — no address in PhonePe's
ranges was ever mitigated — so the edge is not turning PhonePe away.

**Fix it in the PhonePe Business dashboard:** Test Mode OFF → Developer Settings → Webhook → tick the
events (they are opt-in per webhook; a missing tick sends nothing and logs nothing) → the exact URL.
A webhook created with Test Mode ON is a sandbox webhook.

**Add the WAF skip anyway** — PhonePe's sender signature is unknown, and Cloudflare's Browser Integrity
Check answers a `Java/1.8.0_292` User-Agent with **403 / error 1010** on every host (a `Java/17` agent
gets through). Security → WAF → Custom rules → *Skip*: when `ip.src in {103.116.32.16/28 103.116.33.8/30
103.116.33.136/30 103.116.34.1 103.116.34.16/29 103.243.35.242}` AND URI Path starts with
`/payments/webhook`, skip all remaining custom rules AND the Browser Integrity Check. Those are PhonePe's
published webhook source IPs (developer.phonepe.com → Standard Checkout → Webhook → IP Whitelisting).

After either fix, the first `txn:` key in this Worker's KV namespace on the next setup or redemption is
the proof it arrived.
