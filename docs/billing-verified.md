# Billing — verified baseline (2026-07-29)

The known-good record of what the Autopay lifecycle actually does. Read it instead of re-deriving;
re-run `.claude/skills/verify-payments/` when the billing code changes. Endpoint facts and the traps
live in [phonepe.md](phonepe.md).

Exercised against PhonePe **UAT** on a real device (Nothing Phone, PhonePe Simulator) plus a local
stub for the terminal states UAT refuses to settle. Worker `cc00fb34`.

| Step | Proven by | Result |
| --- | --- | --- |
| ₹2 PENNY_DROP trial mandate | device + PhonePe Simulator | authorized; PhonePe `COMPLETED` |
| Repeat subscriber → ₹199 | fresh initiate, trial consumed | `trialEligible:false`, `amountPaise:19900` |
| Double-tap checkout | two concurrent initiates | both 409 `setup_in_progress`, no 2nd mandate |
| 24 h notifier | `next_debit_at` = now+20 h | Pass A notified, **Pass B refused to debit early** |
| ₹199 debit after trial | `next_debit_at` backdated | real UAT `redeem`; UAT holds `PENDING` |
| Debit settles | `subscription.redemption.order.completed` webhook | `active`, period +1 month, `notified_at` cleared |
| Debit fails / dunning | local stub `FAILED` | retries 1–4 alive, **expired at 5**, then ignored |
| Cancellation | `POST /payments/cancel` | `cancelled`, **period stays live**, `next_debit_at` NULL |
| Rebuy after cancel | initiate on cancelled row | `19900` — no ₹2 trial |
| Delete → re-login | `DELETE /me` then real Google sign-in | tombstone written; new row pre-seeded `expired` with the OLD `trial_end` → ₹199 |

## How to re-run it cheaply

- **Time is the only thing simulated.** Notify/redeem/renewal are driven by `next_debit_at`, so
  backdating it is indistinguishable from waiting. Never wait out a real trial day.
- **Local dev cannot receive the real S2S webhook** (`127.0.0.1` is unreachable from PhonePe). Drive
  the handler with `tools/prod-webhook.mjs`; only the final network hop stays unproven locally.
- **Two `wrangler dev` instances can both hold 8787**, and the stale one silently serves the app with
  the old config — that produced a phantom `502 phonepe_error`. Check `netstat -ano | grep :8787`
  before blaming code.
- **Delete KV `phonepe:oauth` when switching between the stub and real UAT**, or a stub-issued token
  is replayed against the real host.

## Not covered by UAT — needs production

**Production webhook delivery for Arul** is the one billing hop UAT and local cannot cover:
PhonePe → `api.hsrutility.com` → `DKS_` dispatcher → arul-api. The same path already works in
production for Pakiza.
