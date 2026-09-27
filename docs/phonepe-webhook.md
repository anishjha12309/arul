# The PhonePe webhook — and why it has never fired

Read before touching webhook handling in `workers/src/routes/payments.ts`. Endpoints, setup and the
heal paths: [phonepe.md](phonepe.md) · recurring debits: [autopay-debits.md](autopay-debits.md).

**No PhonePe webhook has ever been processed in production** — the KV `txn:` prefix holds no key for
any event while the server's own `ph:` marks under the same TTL sit in the hundreds. The cron is the only
channel that has ever worked, so a revoked or paused mandate stays invisible until a debit fails. Never
let the webhook become the only path to a correct row.

## The contract

- `Authorization: SHA256(username:password)`, deduped by **(event, orderId)** in KV with a 30-day TTL —
  the event MUST be in the key, or a later event for the same order is dropped as a duplicate.
- **One webhook per MERCHANT, shared with Pakiza.** Order ids carry the `DKS_` prefix so the two apps'
  streams stay separable (Pakiza's is `PKZ_`). The registered URL is
  `https://api.hsrutility.com/payments/webhook`, the hsr-cms dispatcher, which forwards `DKS_` orders
  here. Test Mode, the ticked events and the SHA password apply to both apps, and the password cannot
  be edited after creation — the Worker secrets must match it.
- **Order events nest the ids under `payload.paymentFlow`**; state-change events keep them top-level.
  Read through `merchantSubscriptionIdOf()` — the flat read acked every real redemption webhook as
  "Missing merchantSubscriptionId".
- Intent-flow setups emit `subscription.setup.order.completed/failed`; the Worker aliases the
  `checkout.order.*` names onto the same branches.

## Where it dies: PhonePe is not sending

Proven by synthetic POSTs to the live URL: the dashboard credentials pass this handler's SHA-256 check
through the hsr-cms relay (`200 ok` on a `DKS_` id matching no row; a wrong password gets
`401 invalid_signature`), so credentials, `DKS_` routing and this handler are correct. The zone's
Security Events for `/payments/webhook` show only the team's own test POSTs — no address in PhonePe's
`103.116.32.0/22` ranges was ever mitigated — so the edge is not turning PhonePe away.

**Fix it in the PhonePe Business dashboard:** Test Mode OFF → Developer Settings → Webhook → tick the
events (they are opt-in per webhook; a missing tick sends nothing and logs nothing) → URL exactly
`https://api.hsrutility.com/payments/webhook`. A webhook created with Test Mode ON is a sandbox webhook.

**Add the WAF skip anyway** — PhonePe's sender signature is unknown, and Cloudflare's Browser Integrity
Check answers a `Java/1.8.0_292` User-Agent with **403 / error 1010** on every host (a `Java/17` agent
gets through). Security → WAF → Custom rules → *Skip*: when `ip.src in {103.116.32.16/28 103.116.33.8/30
103.116.33.136/30 103.116.34.1 103.116.34.16/29}` AND URI Path starts with `/payments/webhook`, skip all
remaining custom rules AND the Browser Integrity Check. Those are PhonePe's published webhook source IPs
(developer.phonepe.com → Webhook Handling → IP Whitelisting).

After either fix, the first `txn:` key in this Worker's KV namespace on the next setup or redemption is
the proof it arrived.
