# Order outcomes — why each renewal order ended

`order_outcomes` (`db/schema/36_order_outcomes.sql`) keeps what PhonePe said about every redemption order.
Without it the reason was lost: a FAILED debit only bumps `retry_count`, and Pass A overwrites
`redemption_order_id` with the next rung's order, so PhonePe could only be asked about each row's LATEST
order. Debits: [autopay-debits.md](autopay-debits.md). Report: `cd workers && node tools/payment-failures.mjs [days]`.

## The recorder never touches billing

`recordOrderOutcome` (`workers/src/lib/order-outcomes.ts`) takes raw objects, coerces every bind to
string/number/null (postgres.js throws on `undefined`) and swallows every error. A lost row is a lost
diagnosis; a thrown one could be a lost debit. Three placement rules, each a way the review found to break
billing with a "fail-open" insert:

- **After the billing write, never before.** Pass A between `notifyRedemption` and its UPDATE: a slow or
  failed insert leaves `notified_at` NULL, the next tick mints a second order, PhonePe refuses that notify
  and the back-off ALARM delays a healthy debit by ~30 h.
- **Awaited in-lane, never fire-and-forget.** postgres.js pipelines onto a busy pooled connection; a query
  that throws while being built rejects whatever query is active on it, which may be another lane's settle.
- **Never between a `budgetLeft` check and its increment, never inside `sql.begin` or a billing CTE.** An
  insert failure inside a CTE fails the park it rides on.

No billing path reads the table. Keep it that way: an entitlement or dunning decision off a diagnosis row
inherits every gap in its capture.

## Events

| Event | Written by | Carries |
| --- | --- | --- |
| `minted` | Pass A, `/internal/run-redemptions` | rung (`retry_count` before the attempt), amount, `expireAt` |
| `redeem_accepted` | Pass B, run-redemptions | PhonePe's state from `redeem` |
| `redeem_rejected` | Pass B catch, PhonePe answers only | HTTP status, body `code`, mandate state when Pass B read it |
| `reconciled` | `reconcileFromOrder`, COMPLETED/FAILED only | `errorCode`, `detailedErrorCode`, rung |
| `recycled` | Pass B dead order / 45-day wall | the non-terminal state it died in |
| `closed` | the hourly closing read | the final word, with `errorContext` |

PENDING and NOTIFIED reads are never recorded: they repeat every tick and say nothing new. The unique index
(order, event, state, code, detailed code) + `ON CONFLICT DO NOTHING` absorbs a tick delivered twice; `minted`
and `closed` are unique per order on their own, or a backfill row (no state) beside Pass A's (NOTIFIED) made the
closing read fetch one order twice.
A network throw on `redeem` is not a rejection — PhonePe never answered — so only `PhonePeApiError` writes one.

## The closing read is the only reliable capture

A parked, paused or recycled row keeps a stale order nobody re-reads, and the legacy merchant sends no
webhook, so most SUBSCRIPTION_DEBIT_SKIPPED orders were never seen. The last hourly sweep
(`closeOrderOutcomes`) reads every `minted` order with no `closed` row once it is past its own `expireAt`
(+1 h; `observed_at` + 72 h when unknown), 60 an hour on the run's leftover budget, 2 calls reserved per row.
ORDER_NOT_FOUND closes as `NOT_FOUND`; a 5xx writes nothing and retries next hour. A pass error is caught:
the log must never cost the run its idle marker.

## errorContext — undocumented on autopay, so never on the billing read

`?errorContext=true` returns `{source, stage, description}` (CUSTOMER, ISSUING_BANK, NPCI, BUSINESS, OTHERS).
PhonePe documents it for checkout orders only; on `/subscriptions/v2/order/{id}/status` it answers, but
`getOrderStatus` feeds every settle, so a refusal there would stop all renewals silently. Only
`getOrderOutcome` sends it, and on a 400 that is not ORDER_NOT_FOUND it re-reads once without it.
PhonePe's published code table lacks codes we receive (UPI_BACKBONE_ERROR, NU, XC,
SUBSCRIPTION_DEBIT_SKIPPED): store what the read returns, never a lookup.

## BUSINESS does not mean "our bug"

PhonePe pins SUBSCRIPTION_DEBIT_SKIPPED ("skipped for this billing cycle", no attempt in `paymentDetails`)
on the merchant: an order reached `expireAt` with no `redeem`. That is correct after every park — we stop
redeeming a revoked or paused mandate. BUSINESS also covers PhonePe-side glitches (U66 and others). Our
bug looks like: SKIPPED, mandate ACTIVE at the closing read, and NO `redeem_*` row for the order — Pass B
starvation. The closing read records the mandate state for every skip; the report splits skips that way,
and a backfilled order's redeem is unknown — nothing recorded redeem calls before the log existed.

## Retention and privacy

Owner's call: one row per order per person, 12 months, then `pruneOrderOutcomes` in the `30 21` cron.
Codes and timestamps only — never VPA, UTR, UMN, account number or holder name, all of which
`paymentDetails` carries. `user_id` cascades with account deletion. No grant to `posthog_reader`: PostHog
reads only `posthog_renewal_outcomes_daily` (`38_*`), totals per day, state and code, recomputed every sync.

## Backfill

History before the table exists only through order ids found elsewhere. Load them as `minted` rows with
`observed_by = 'backfill:<source>'`, `retry_rung` NULL unless the source knew it, and an `expire_at` in the
past; the closing read then fetches each reason. Their mandate state is as of that read, not the failure.
Load through a reviewed `INSERT … ON CONFLICT DO NOTHING` via `prod-sql.mjs --write`, joined to `users`
(a deleted account's id would fail the FK). Sources that age out daily: Neon point-in-time history and
Workers Logs (both 7 days on our plans; the reconcile line prints our `DKS_R_` id).
