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

⚠ **No PhonePe webhook has ever been processed in production.** The `txn:` prefix in KV holds ZERO
keys for any event, including setup confirmations, while the server's own `ph:` marks sit in the
hundreds under the same 30-day TTL — so this is not a stale reading. **The cause is outside this
repo**: either the events are not ticked on the webhook in the PhonePe Business dashboard, or the
dispatcher is not forwarding `DKS_`. Until it is fixed the cron is the ONLY channel, and revoked or
paused mandates are invisible until a debit fails.

One webhook per MERCHANT, shared with Pakiza: Test-Mode, the selected events and the SHA password
apply to both, and the password is not editable after creation, so the Worker secrets must match it.
**Events are opt-in per webhook**, so a missing tick sends nothing and logs nothing.
