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

## Pass A — only a status-read 4xx parks, and only a never-debited mandate

A status-read 4xx parks a never-debited row `cancelled` (`rejected_by_phonepe`); `phonepe_subscription_id` is
on ~every row, so it proves nothing. A notify 4xx after an ACTIVE read, or any 4xx on a debited mandate, logs
`ALARM` and moves `next_debit_at` 6 h past the notify window (no LIMIT slot); past the 45-day wall it parks. A
revoked mandate reads `REVOKED`, never a 4xx. Cloudflare can deliver one tick twice from two colos: the second
notify on an open order is refused, and parking it once cancelled a whole tick of live trials. The back-off
requires `notified_at IS NULL`, so a row the other run notified keeps its order.

## Pass B's slots are the scarce resource

- **Skip any row notified under 24 h ago without a call** — PhonePe refuses inside its notify window,
  and a recycled order re-notified by Pass A was executed in the same run, every run.
- **An order older than PhonePe's 48 h retry window (aged from `notified_at`) is reconciled on the
  top-of-hour tick only** — it can settle only through PhonePe's own retries. That deferral is a bound
  in Pass B's `WHERE`, not a skip in its loop: the loop runs under `LIMIT MAX_ROWS_PER_PASS`, and a
  ruled-out row still spent a slot, starving fresh debits behind an old head. `isTopOfHourTick()` is
  read ONCE per run and shared by the bound and the skip, so a run crossing a 15-minute boundary never
  fetches a row under one rule and drops it under the other.
- **Fresh debits first, then stuck ones least-recently-checked first.** A PENDING reconcile writes
  nothing, so oldest-due-first re-picked the same 200 in-flight orders every tick and no newer debit
  was ever redeemed; a PENDING check now bumps `updated_at` (guarded by the order id), the Pass D
  rotation.
- **Pass B runs 4 lanes over one list** (800 rows, 2,400 calls a run). Workers queue a 7th connection
  still waiting for headers, so more lanes only queue. The PhonePe token is fetched once before the lanes
  start, and no budget check straddles an await, so the lanes cannot race either.
- **Starvation symptom:** a growing WAITING list while `retry_count` stays 0 and no `Execute … state=`
  lines appear for the youngest due rows.

## Pass D — parked pauses

A `paused` row has `next_debit_at` NULL and a status outside `('trialing','active')`, which removes it
from both passes; the only other ways back are a webhook that has never arrived and the user opening
the paywall. So on the top-of-hour tick Pass D re-asks PhonePe about up to `MAX_PAUSED_RECHECK` rows,
oldest `updated_at` first: ACTIVE restores and rearms through `lib/subscription-rearm.ts` (one copy with
the webhook, or one forgets the clock), a terminal state parks it `cancelled`, anything else only moves
`updated_at` so a backlog rotates. It spends the same per-run call budget, checked per row, so a debit
always outranks it. Pass D and the sweeps below always have a book to read, so the KV idle marker
(`autopay:next_work_at`) never reaches past the next top of the hour.

## The hourly sweeps (`autopay-sweeps.ts`)

No legacy webhook exists and an app killed in the UPI app never reports back, so these PULL.
Top-of-hour only, after Pass D, 4 lanes on the leftover budget, no row started past 10 min. A pass must move each row out of its own selection, or that row heads it every hour.

- **Settled debits:** a never-converted non-live row with an order: COMPLETED → `healSettledDebit` (a
  revoked mandate keeps the month `cancelled`); FAILED, expired or never created → drop the order id.
  Claims under 30 min wait: the user may be approving right now.
- **Stranded claims** (`pending` > 30 min): COMPLETED → grant, but a ₹2 setup done > 24 h ago is revoked
  and released (a trial now = a surprise ₹199 tomorrow); a ₹199 TRANSACTION always grants. FAILED,
  EXPIRED, never created → release; open > 2 h → revoke + release; a read error changes nothing.
- **Legacy mandates:** ~120/h, least-recently-checked: REVOKED/CANCELLED → `cancelled`, PAUSED → park,
  else only `updated_at` moves.
- ₹99 watch, revoke retries: [cancel-offer.md](cancel-offer.md).

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

Every paid grant stamps `first_debit_at`/`debit_count`/`paid_paise` (+ the row's `price_paise`) on the
SAME statement as the `active` flip — the columns and the `addOneMonth` trap: [data-model.md](data-model.md).

## Testing

`workers/test/autopay-notify.test.ts`. The load-bearing case is **redeem throws BECAUSE the order
already settled** — assert the row still ends `active`. Sandbox settles synchronously and the bug needs
a second cron tick, so only mocks cover it; show a new test failing against the pre-fix code before
trusting it.
