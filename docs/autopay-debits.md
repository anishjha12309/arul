# Autopay recurring debits — the settle path

Read before touching `workers/src/cron/autopay-notify.ts`. Split out of
[phonepe.md](phonepe.md), which owns setup and cancel; this owns what happens when a trial ends and
money must actually move. Every line was paid for by a live incident.

## The rule that outranks everything here

**Order status is the authority. `redeem` is only a trigger.** A UPI debit settles SECONDS AFTER
PhonePe accepts the redeem call, so the redeem response is routinely non-terminal on a debit that is
about to succeed. Never treat it as the verdict, and never let the reconcile that reads the real
state sit behind a call that can throw.

That exact mistake cost real money: the reconcile lived inside the `try`, BELOW `executeRedemption`.
Once the order settled, every later run threw on re-redeem, skipped the reconcile, and left the row
untouched. Two subscribers were debited ₹199, stayed `trialing`, and lost premium for two days. Neon's
"revenue truth" said zero revenue while PhonePe held the money. Pass A could not rescue them either —
it selects `notified_at IS NULL`, and theirs was set.

So Pass B now: **reconcile first** (when overdue past `RECONCILE_STUCK_AFTER_MS`) → redeem only if
still open → **reconcile again inside the catch**. A throw is never evidence the debit failed.

## Error codes seen on `/subscriptions/v2/redeem` (all HTTP 400)

| Code | Means | Do |
| --- | --- | --- |
| `INVALID_SUBSCRIPTION_STATE` | The mandate is gone at PhonePe (user revoked it at their bank) | Read mandate status; park the row `cancelled` |
| `DUPLICATE_TXN_REQUEST` | *"Another redemption request is not allowed for PHONEPE_CONTROLLED retry strategy"* — PhonePe owns the retry now | Do NOT re-redeem. Poll order status and wait |
| `SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED` | Executed less than 24 h after the order's notify — the mandatory pre-debit notice window. Seen on every RECYCLED order | Nothing — Pass B skips rows notified under 24 h ago without a call. Never treat as a failed debit |
| `BAD_REQUEST` — *"Previous transaction is not in terminal state"* | PhonePe's own attempt on this order is still open. Means exactly what `DUPLICATE_TXN_REQUEST` means, in different words | Do NOT re-redeem. **OPEN DEFECT: the `inFlight` test matches only the `DUPLICATE_TXN_REQUEST` string**, so this logs `Execute failed` at ERROR and spends a mandate-status call on a healthy debit — widen the test |

**Where the fourth one comes from:** it lands on rows overdue by LESS than `RECONCILE_STUCK_AFTER_MS`,
which is the window where no reconcile runs first and the redeem goes out blind — `trialing`,
`retry_count 0`, notified 24–26 h ago. 5–6 per tick on 8 Sep 2026. It self-corrects once the row
passes 2 h overdue and reconcile-first starts reporting PENDING, and parking stays gated on a
terminal mandate state, so no row is at risk. It is noise that reads as failure, which is the one
thing this file says trains everyone to ignore the line that will one day be real.

All four are 4xx, so `PhonePeApiError.isPermanent` is true — but permanent means "this CALL cannot
succeed", NOT "the debit failed". `DUPLICATE_TXN_REQUEST` in particular fires on debits that are
mid-flight and will succeed. **Never expire a row on a redeem error alone.**

**The starvation those two rules compound into:** each recycled row at the head of the oldest-first
list burned subrequests per tick on that 400, the run hit the subrequest cap around row 20, and the
fresh cohorts behind it were never executed — their orders then aged past 72 h, got recycled, and
joined the failing head. Zero conversions for over a day with dozens due. Fixed by the 24 h gate, a
per-run PhonePe call budget and the quarter-hour trigger ([cron.md](cron.md)). Symptom to recognise:
a growing WAITING list while `retry_count` stays 0 and no `Execute … state=` lines appear for the
youngest due rows.

**We send `redemptionRetryStrategy: "STANDARD"` at notify, and PhonePe still reports the order as
PHONEPE_CONTROLLED afterwards.** Treat the first redeem as the trigger and every later one as noise:
Pass B skips the redeem outright when reconcile reports `PENDING`, and logs a stray duplicate as
INFO. That is log hygiene, not thrift — an hourly `(error) Execute failed` on a debit that is
perfectly healthy trains everyone to ignore the line that will one day be real. A `null` state (the
status read itself failed) is NOT a skip: it tells us nothing, so the redeem still runs.

## Order states

`COMPLETED | FAILED | PENDING | NOTIFIED`. **`NOTIFIED` is redemption-only** — announced, not yet
executed — and it is the state an order occupies for its whole 24 h notify window, so it is the
COMMONEST state in a healthy population, not a fault signal. A revoked mandate's order can sit at it
too, which is why it must never be read as "stuck" on its own: check the order's age against
`notified_at` first. It is NOT in PhonePe's documented list; it was observed live. **Treat any
unrecognised state as non-terminal.**

An order carries its own `expireAt` (notify + 72 h observed). Past that PhonePe will never settle it
and re-redeeming can only 4xx: clear `notified_at` and `redemption_order_id` so Pass A mints a fresh
order. **Only ever recycle off a SUCCESSFUL status read** — recycling because a status call errored
could mint a second order and debit the user twice.

## Dunning — the 45-day ladder (owner's call)

A FAILED debit reschedules itself by pushing `next_debit_at` to `current_period_end` + day **2, 5,
10, 20, 32, 45** (`RETRY_OFFSET_DAYS`; `retry_count` is the index), aligned FORWARD to the next
21:30 UTC = 03:00 IST — inside NPCI's non-peak execute window. Past the last rung the row expires.

**Anchor on `current_period_end`, never on `now()`** — the failure path does not move it, so the
schedule cannot drift however late a reconcile lands.

Each rung is a fresh notify+order, which is the compliant unit: PhonePe's 1-attempt-plus-3-retries
cap applies INSIDE one order, nothing caps notify cycles per subscription, and the ≥2-day gap means
a new order never overlaps the last one's retry window. The same 45 days is a WALL on the recycle
path: a row whose orders die non-terminally (forever NOTIFIED) never advances the ladder and used to
mint orders without bound — past the wall it expires instead.

The webhook's `redemption.*.failed` branch is **LOG-ONLY**: the cron's reconcile owns the FAILED
transition, exactly once per order. A webhook increment advanced the index without scheduling (a
skipped rung) and double-counted beside the cron's own +1.

Entitlement is untouched — premium still ends at period end plus grace while dunning runs in the
background, and a mid-ladder settle grants the month from the settle date with `retry_count` reset.

## The rules the ladder is built to satisfy (checked 17 Sep 2026)

- **RBI, Digital Payments – E-mandate Framework, 2026** (RBI/DPSS/2026-27/396, 21 Apr 2026; it repeals
  the 2019–2024 circulars): the issuer must send a pre-debit notification **at least 24 h before the
  debit** (§6(a), a floor with no ceiling); recurring debits up to **₹15,000 need no AFA** (§8(a)), so a
  ₹199 debit never asks for a PIN; the customer can withdraw or opt out of the mandate at any time
  (§4(b), §6(c)). Every ladder rung is a fresh notify ≥24 h before its redeem, which is what keeps a
  retry inside §6(a).
- **PhonePe Autopay v2 (redemption-notify / redemption-execute reference):** inside ONE order the cap is
  1 attempt + 3 retries within a 48 h window (`expireAt` default 48 h; 72 h has been observed), retries
  only in the non-peak bands 21:31–09:59 and 13:01–16:59 IST, and `STANDARD` means PhonePe runs those
  retries itself. The ladder's rungs sit at 03:00 IST, inside the night band, and are ≥2 days apart, so
  no rung overlaps the previous order's window.
- **No RBI or NPCI text caps how many days after the due date fresh notify+redeem cycles may continue**,
  and none forbids retrying an insufficient-funds failure on a later day. The 45-day wall is the owner's
  call, not a regulatory one. NPCI OC-223 (7 Oct 2025) is about mandate portability and the central
  "My Mandates" revoke portal, not retries.

## The webhook is the fast path, the cron is the correct one

The webhook flips the row in seconds and is the only channel that reports `subscription.revoked` or
`paused` at all. But it is a PUSH: a lost delivery is lost forever. The cron is a PULL, so it can
always re-ask. **The cron is what makes billing self-healing; the webhook only makes it fast.** Never
let a webhook-shaped optimisation become the only path to a correct row.

No webhook has ever actually arrived in production — cause and evidence in
[phonepe-webhook.md](phonepe-webhook.md).

## Every paid grant stamps the debit-tracking columns

`first_debit_at = COALESCE(first_debit_at, now())`, `debit_count + 1` and `paid_paise + 19900` ride on the
SAME statement as the `active` flip — `applyDebitOutcome`, the webhook's redemption branch, `run-redemptions`,
and the three setup grants in `payments.ts`, whose ELSE branch is a real ₹199. Nothing in this Worker reads
them; the unified CMS's subscriptions page does, for the day-by-day ledger and the retention-by-first-
payment-month table; rows debited before the columns existed were backfilled once by
`db/schema/23_debit_backfill.sql` (settle time recovered from `updated_at`, or `current_period_end` minus one
month when the row was touched again afterwards); and the page still derives a "tracking since" date from any
paid row with no stamp, so if that date ever appears again a grant path stopped stamping — that is the alarm.
`addOneMonth` uses JavaScript's `setMonth`, so 31 Aug + 1 month lands on 1 Oct, and any SQL that reverses a
period end back to a settle date must not assume `interval '1 month'`. Schema:
`db/schema/14_debit_tracking.sql`, applied BEFORE the Worker that writes it, or every settle UPDATE fails
while PhonePe keeps the money.

## Testing this

`test/autopay-notify.test.ts` — the cron shipped with no test at all, which is how the above reached
production. The load-bearing case is **redeem throws BECAUSE the order already settled**; assert the
row still ends `active`. Sandbox cannot reproduce it (it settles synchronously) and neither can a
single-run test (the bug needs a second cron tick), so it must be covered by mocks, and a new test
must be shown to fail against the pre-fix code before it is trusted.
