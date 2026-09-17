# The PhonePe webhook — and why it has never fired

Read before touching webhook handling in `workers/src/routes/payments.ts`. Split out of
[phonepe.md](phonepe.md), which owns the endpoints, mandate setup and recovery paths; recurring
debits are [autopay-debits.md](autopay-debits.md).

**The cron is the only channel that has ever worked.** Everything below is why, and what has to be
true before a webhook can be trusted with anything.

`Authorization: SHA256(username:password)`, deduped by **(event, orderId)** in KV with a 30-day TTL —
the event MUST be in the key. The order-id prefix is `DKS_`, which is how the shared merchant's
streams stay distinguishable from Pakiza's `PKZ_`. The registered URL is
`https://api.hsrutility.com/payments/webhook`, the hsr-cms dispatcher that forwards `DKS_` orders on.

**Order events nest the ids under `payload.paymentFlow`**; state-change events keep them top-level.
Read via `merchantSubscriptionIdOf()`. The flat read acked every real redemption webhook as "Missing
merchantSubscriptionId".

Intent-flow setups emit `subscription.setup.order.completed/failed`; the Worker aliases the
`checkout.order.*` names onto the same branches, so it is safe either way.

## Where it dies — narrowed on 17 Sep 2026, not yet proven

What IS proven, by synthetic POSTs to the live `https://api.hsrutility.com/payments/webhook`:
the dashboard credentials (username `pakiza_phonepe_hook`, one webhook per merchant so both apps
share it) pass this handler's SHA-256 check through the hsr-cms relay (`200 ok` on a `DKS_` id that
matches no row; a wrong password gets `401 invalid_signature`), so credentials, `DKS_` routing and
this handler are all correct. Both KV namespaces hold zero `txn:` marks against 1,121 `ph:` order
marks in Arul alone, so nothing has ever arrived at either Worker.

What is NOT proven is where the delivery dies. Two candidates, one decisive check:

1. **Cloudflare's edge rejects PhonePe's sender before any Worker runs.** A `Java/1.8.0_292`
   User-Agent gets **HTTP 403, error 1010** (Browser Integrity Check) on this route — but also on
   `www.cloudflare.com`, so that is Cloudflare's default treatment of that signature everywhere, and
   a `Java/17` agent reaches the Worker. It explains everything only if PhonePe's sender carries a
   signature Cloudflare bans, which nobody has seen.
2. **PhonePe is not sending**: the webhook was created with the dashboard's Test Mode toggle ON
   (a sandbox webhook), or with no events ticked, or it points somewhere else. Events are opt-in.

**The check that settles it:** Cloudflare dashboard → `hsrutility.com` → Security → Events, filter
URI Path contains `/payments/webhook`. Blocked events from `103.116.32.0/22` = candidate 1. No
events at all from those addresses = candidate 2, fix it in the PhonePe Business dashboard
(Test Mode OFF → Developer Settings → Webhook → the events ticked → URL exactly
`https://api.hsrutility.com/payments/webhook`).

**The fix for candidate 1 is a zone rule, not code, and it is worth adding either way:** Security →
WAF → Custom rules → *Skip*: when `ip.src in {103.116.32.16/28 103.116.33.8/30 103.116.33.136/30
103.116.34.1 103.116.34.16/29}` AND URI Path starts with `/payments/webhook`, skip all remaining
custom rules AND the Browser Integrity Check. Those are PhonePe's published webhook source IPs
(developer.phonepe.com → Webhook Handling → IP Whitelisting: 103.116.33.8–11, 103.116.33.136–139,
103.116.32.16–29, 103.116.34.1, 103.116.34.16–23). After either fix, watch this namespace for its
first `txn:` key on the next setup or redemption.

⚠ **No PhonePe webhook has ever been processed in production.** The `txn:` prefix in KV holds ZERO
keys for any event, including setup confirmations, while the server's own `ph:` marks sit in the
hundreds under the same 30-day TTL — so this is not a stale reading. **The cause is outside this
repo**: either the events are not ticked on the webhook in the PhonePe Business dashboard, or the
dispatcher is not forwarding `DKS_`. Until it is fixed the cron is the ONLY channel, and revoked or
paused mandates are invisible until a debit fails.

One webhook per MERCHANT, shared with Pakiza: Test-Mode, the selected events and the SHA password
apply to both, and the password is not editable after creation, so the Worker secrets must match it.
**Events are opt-in per webhook**, so a missing tick sends nothing and logs nothing.
