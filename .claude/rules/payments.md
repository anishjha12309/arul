---
description: PhonePe Autopay invariants — setup, cancel and the recurring debit path.
paths:
  - "workers/src/routes/payments.ts"
  - "workers/src/lib/phonepe.ts"
  - "workers/src/cron/autopay-notify.ts"
---

Real money moves here and several PhonePe docs are wrong, so never re-derive an endpoint, a payload
shape or a status vocabulary from memory.

- **Order status is the authority; `redeem` is only a trigger.** A UPI debit settles seconds after
  PhonePe accepts the call, so the redeem response is routinely non-terminal on a debit that is about
  to succeed. Never expire a row on a redeem error alone, and never let the reconcile sit behind a
  call that can throw.
- **A failed or abandoned setup RESTORES to `cancelled` while the period lives, never `expired`.** A
  resubscribe claims the user's ONE row, so paid days must survive the attempt.
- **Never fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW — a
  web-checkout token answers PR004 on device while the Worker returns 200.
- **Never execute inside PhonePe's 24 h notify window**, and treat any unrecognised order state as
  non-terminal.
- The 409 `setup_in_progress` window and the app's initiate retry delays are paired by arithmetic —
  change either side only with the other.
- Set secrets with `wrangler secret bulk`, never a shell pipe; delete the cached `phonepe:oauth` KV
  key after any env or credential change.

Read [docs/phonepe.md](../../docs/phonepe.md) before changing setup, cancel or the webhook, and
[docs/autopay-debits.md](../../docs/autopay-debits.md) before changing the cron's passes or the
dunning ladder. Re-prove a billing change with `.claude/skills/verify-payments/`.
