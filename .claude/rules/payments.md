---
description: PhonePe Autopay invariants — setup, cancel and the recurring debit path.
paths:
  - "workers/src/routes/payments.ts"
  - "workers/src/lib/phonepe.ts"
  - "workers/src/cron/autopay-notify.ts"
---

Real money moves here and several PhonePe docs are wrong: never re-derive an endpoint, payload shape
or status vocabulary from memory.

- **Order status is the authority; `redeem` is only a trigger.** A UPI debit settles seconds after
  PhonePe accepts, so the redeem answer is usually non-terminal. Never expire a row on a redeem
  error alone, never put the reconcile behind a call that can throw.
- **A failed or abandoned setup RESTORES to `cancelled` while the period lives, never `expired`.** A
  resubscribe claims the user's ONE row, so paid days must survive the attempt.
- **Initiate PARKS a `trialing`/`active`/`paused` mandate in `superseded_mandate_id`, never revokes
  it** — it is still billing; the grant revokes it, every release path restores it.
- **Never fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW — a web
  token answers PR004 on device while the Worker returns 200.
- **Never execute inside PhonePe's 24 h notify window**, and treat any unrecognised order state as
  non-terminal.
- The 409 `setup_in_progress` window and the app's initiate retry delays are paired by arithmetic —
  change either side only with the other.
- Set secrets with `wrangler secret bulk`, never a shell pipe; delete the cached `phonepe:oauth` KV
  key after any env or credential change.
- **Every paid-period grant stamps `first_debit_at` / `debit_count` / `paid_paise` on the same
  UPDATE** — the CMS subscriptions page reads nothing else.

Read [docs/phonepe.md](../../docs/phonepe.md) before changing setup or cancel,
[docs/phonepe-webhook.md](../../docs/phonepe-webhook.md) before the webhook, and
[docs/autopay-debits.md](../../docs/autopay-debits.md) before the cron or the ladder. Re-prove a
billing change with `.claude/skills/verify-payments/`.
