# Autopay recurring debits — the settle path

Read before touching `workers/src/cron/autopay-notify.ts`. Setup and cancel: [phonepe.md](phonepe.md).
Its trigger and budgets: [cron.md](cron.md). Every rule here was paid for by a live incident.

## Order status is the authority; `redeem` is only a trigger

A UPI debit settles SECONDS AFTER PhonePe accepts the redeem call, so the redeem response is routinely
non-terminal on a debit about to succeed. The reconcile once lived inside the `try` BELOW
`executeRedemption`: once the order settled, every later run threw on re-redeem and skipped the
reconcile, so subscribers were debited ₹199, stayed `trialing` and lost premium while Neon showed no
revenue. Pass A could not rescue them — it selects `notified_at IS NULL`.

So Pass B: **reconcile first** (when overdue past `RECONCILE_STUCK_AFTER_MS`) → redeem only if still
open → **reconcile again inside the catch**. A throw is never evidence the debit failed, and **never
expire a row on a redeem error alone.**

## Error codes on `/subscriptions/v2/redeem` (all HTTP 400)

| Code | Means | Do |
| --- | --- | --- |
| `INVALID_SUBSCRIPTION_STATE` | The mandate is gone at PhonePe (revoked at the bank) | Read mandate status; park the row `cancelled` |
| `DUPLICATE_TXN_REQUEST` | PhonePe owns the retry ("PHONEPE_CONTROLLED") | Never re-redeem; poll order status |
| `SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED` | Executed inside the 24 h pre-debit notice window | Nothing — Pass B never calls inside it |
| `BAD_REQUEST` "Previous transaction is not in terminal state" | Same as `DUPLICATE_TXN_REQUEST`, other words | Never re-redeem |

**OPEN DEFECT: the `inFlight` test matches only the `DUPLICATE_TXN_REQUEST` string**, so the fourth
code logs `Execute failed` at ERROR and spends a mandate-status call on a healthy debit — widen the
test. It lands on rows overdue by less than `RECONCILE_STUCK_AFTER_MS`, where no reconcile runs first,
and self-corrects past 2 h overdue; parking stays gated on a terminal mandate state, so no row is at risk.

All four are 4xx, so `PhonePeApiError.isPermanent` is true — but permanent means "this CALL cannot
succeed", NOT "the debit failed".

**We send `redemptionRetryStrategy: "STANDARD"` at notify and PhonePe still reports the order
PHONEPE_CONTROLLED.** Treat the first redeem as the trigger and every later one as noise: skip the redeem
when reconcile reports `PENDING`, log a stray duplicate as INFO. That is log hygiene — an hourly
`Execute failed` on a healthy debit trains everyone to ignore the line that will one day be real. A
`null` state (the status read itself failed) tells us nothing, so the redeem still runs.

## Pass A — a 4xx parks only a mandate never debited

A permanent 4xx at status or notify parks the row `cancelled` (`rejected_by_phonepe`) ONLY when it was never
debited (`debit_count = 0`) — `phonepe_subscription_id` is on ~every row, so it proves nothing, and trial parks
feed the CMS and PostHog cancel counts. A debited mandate that is revoked reads `REVOKED`, not a 4xx, so a 4xx
there is a misroute, a PhonePe bug or a config slip — one fault answers for every due row at once, and
parked-cancelled stops billing for good. Those rows log `ALARM` and
move `next_debit_at` past the notify window by 6 h (a bound in the WHERE, so they take no LIMIT slot); past the
45-day wall they park as before.

## Pass B's slots are the scarce resource

- **Skip any row notified under 24 h ago without a call** — PhonePe refuses inside its notify window,
  and a recycled order re-notified by Pass A was executed in the same run, every run.
- **An order older than PhonePe's 48 h retry window (aged from `notified_at`) is reconciled on the
  top-of-hour tick only** — it can settle only through PhonePe's own retries. That deferral is a bound
  in Pass B's `WHERE`, not a skip in its loop: the loop runs under `LIMIT MAX_ROWS_PER_PASS`, and a
  ruled-out row still spent a slot, starving fresh debits behind an old head. `isTopOfHourTick()` is
  read ONCE per run and shared by the bound and the skip, so a run crossing a 15-minute boundary never
  fetches a row under one rule and drops it under the other.
- **Starvation symptom:** a growing WAITING list while `retry_count` stays 0 and no `Execute … state=`
  lines appear for the youngest due rows.

## Pass D — parked pauses

A `paused` row has `next_debit_at` NULL and a status outside `('trialing','active')`, which removes it
from both passes; the only other ways back are a webhook that has never arrived and the user opening
the paywall. So on the top-of-hour tick Pass D re-asks PhonePe about up to `MAX_PAUSED_RECHECK` rows,
oldest `updated_at` first: ACTIVE restores and rearms through `lib/subscription-rearm.ts` (one copy with
the webhook, or one forgets the clock), a terminal state parks it `cancelled`, anything else only moves
`updated_at` so a backlog rotates. It spends the same per-run call budget, checked per row, so a debit
always outranks it. While any paused row exists the KV idle marker (`autopay:next_work_at`) may never
reach past the next top of the hour, or a quiet population would skip every `:00` tick.

## Order states

`COMPLETED | FAILED | PENDING | NOTIFIED`. **`NOTIFIED` is redemption-only** — announced, not executed —
and an order occupies it for its whole 24 h notify window, so it is the COMMONEST healthy state, not a
fault. A revoked mandate's order can sit there too: check the order's age against `notified_at` before
calling it stuck. It is not in PhonePe's documented list. **Treat any unrecognised state as
non-terminal.**

An order carries its own `expireAt` (notify + 72 h observed). Past it PhonePe never settles and
re-redeeming only 4xxs: clear `notified_at` and `redemption_order_id` so Pass A mints a fresh order.
**Recycle only off a SUCCESSFUL status read** — recycling on an errored call could mint a second order
and debit twice.

## Dunning — the 45-day ladder (owner's call)

A FAILED debit pushes `next_debit_at` to `current_period_end` + day **2, 5, 10, 20, 32, 45**
(`RETRY_OFFSET_DAYS`; `retry_count` is the index), aligned FORWARD to the next 21:30 UTC = 03:00 IST,
inside NPCI's non-peak execute window. Past the last rung the row expires. **Anchor on
`current_period_end`, never `now()`** — the failure path never moves it, so the schedule cannot drift.

Each rung is a fresh notify+order: PhonePe's 1 attempt + 3 retries cap applies INSIDE one order, nothing
caps notify cycles per subscription, and the ≥2-day gap keeps a new order clear of the last one's retry
window. The same 45 days is a WALL on the recycle path — a row whose orders die non-terminally never
advances the ladder and once minted orders without bound.

The webhook's `redemption.*.failed` branch is **LOG-ONLY**: the cron's reconcile owns the FAILED
transition, once per order. A webhook increment skipped a rung and double-counted. Entitlement is
untouched while dunning runs; a mid-ladder settle grants the month from the settle date and resets
`retry_count`.

**The rules the ladder satisfies.** RBI E-mandate Framework (RBI/DPSS/2026-27/396, which repeals the
2019–2024 circulars): pre-debit notice **≥ 24 h** before the debit (§6(a), a floor), no AFA up to
**₹15,000** (§8(a)), withdrawal at any time (§4(b), §6(c)). PhonePe Autopay v2: inside one order,
1 attempt + 3 retries in a 48 h window, retries only in the non-peak bands 21:31–09:59 and 13:01–16:59
IST. No RBI or NPCI text caps how many days fresh cycles may continue after the due date; the 45-day
wall is the owner's call. NPCI OC-223 concerns mandate portability, not retries.

## The webhook is the fast path, the cron the correct one

A push that is lost is lost forever; the cron is a PULL and can always re-ask, which is what makes
billing self-healing. Never let a webhook-shaped optimisation become the only path to a correct row —
no webhook has ever arrived ([phonepe-webhook.md](phonepe-webhook.md)).

Every paid grant stamps `first_debit_at`/`debit_count`/`paid_paise` on the SAME statement as the
`active` flip — the columns and the `addOneMonth` trap: [data-model.md](data-model.md).

## Testing

`workers/test/autopay-notify.test.ts`. The load-bearing case is **redeem throws BECAUSE the order
already settled** — assert the row still ends `active`. Sandbox settles synchronously and the bug needs
a second cron tick, so only mocks cover it; show a new test failing against the pre-fix code before
trusting it.
