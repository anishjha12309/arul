/**
 * Autopay cron — PhonePe Standard Checkout v2 (OAuth / O-Bearer). Two passes per run.
 *
 * It owns the quarter-hour cron trigger ALONE -> it never shares an invocation's wall clock or call budget
 * Folding it back into the hourly catalog trigger blew the subrequest cap mid-scan -> never do that again
 * The Notify API must be called BEFORE the debit date; Execute (redeem) only AT or after it
 * Pass A NOTIFY: rows trialing/active, next_debit_at within the window, notified_at NULL -> verify ACTIVE, then notify
 * Pass B EXECUTE: rows notified >= 24h ago and due -> redeem -> COMPLETED extends a month, FAILED climbs the ladder
 * PENDING is left alone in both -> PhonePe's STANDARD strategy is still retrying it -> a second redeem is a 4xx
 * sendUserNotification is a log-only stub BY DESIGN -> Arul has no push channel -> PhonePe delivers the payer notice
 */

import type { Env } from "../env.js";
import { getDb, toDate } from "../lib/db.js";
import {
  reportPostHogFirstConversion,
  reportPostHogSubscriptionCancel,
  type SubscriptionCancelReason,
} from "../lib/posthog.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  notifyRedemption,
  executeRedemption,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantOrderId,
  PhonePeApiError,
} from "../lib/phonepe.js";

/** States PhonePe will never debit from again -> the answer is authoritative -> stop retrying the row, do not re-ask. */
const TERMINAL_MANDATE_STATES = new Set([
  "REVOKED",
  "CANCELLED",
  "EXPIRED",
  "FAILED",
]);

/**
 * The dunning ladder — days after the ORIGINAL due date at which each retry of a FAILED debit runs.
 *
 * The anchor is current_period_end, which the failure path NEVER moves -> the schedule cannot drift
 * Owner's rule: pursue a failed renewal for 45 days, spaced -> 7 attempts, not 45
 * Each rung is a FRESH notify + order -> that is the compliant unit
 * PhonePe's 1-attempt+3-retries/48h cap applies INSIDE one redemption order, and nothing caps notify cycles
 * The RBI 24h pre-debit notice rides Pass A's re-notify -> a rung without a fresh notify would be non-compliant
 * Spaced, not daily -> every rung pings the user through PhonePe's rails, and most recoveries happen in week one
 * The minimum 2-day gap also guarantees a new order never overlaps the previous order's 48h retry window
 * retry_count is the ladder INDEX -> walking off the end expires the row
 */
const RETRY_OFFSET_DAYS = [2, 5, 10, 20, 32, 45];

/**
 * The same 45-day rule as a hard wall on the RECYCLE path — the ladder alone cannot enforce it.
 * A row stuck forever NOTIFIED never goes terminal -> the FAILED ladder never advances -> it minted orders unbounded
 */
const DUNNING_WINDOW_MS = 45 * 24 * 60 * 60 * 1000;

/**
 * Land a ladder retry at the next 21:30 UTC (03:00 IST) at or after anchor+offset.
 *
 * NPCI executes autopay only in non-peak windows -> 21:31-09:59 and 13:01-16:59 IST
 * 03:00 IST puts BOTH the notify (~24h earlier, also ~03:00 IST) and the execute inside that window
 * Otherwise the timing is whenever the debit happened to fail -> that lands retries in peak hours
 * Alignment only ever moves FORWARD, by at most 24h -> a retry can never fire earlier than its rung
 */
function nonPeakRetryAt(anchor: Date, offsetDays: number): Date {
  const due = new Date(anchor.getTime() + offsetDays * 24 * 60 * 60 * 1000);
  const aligned = new Date(due);
  aligned.setUTCHours(21, 30, 0, 0);
  if (aligned.getTime() < due.getTime()) aligned.setUTCDate(aligned.getUTCDate() + 1);
  return aligned;
}

/**
 * How long past due a debit may sit un-settled before we stop trusting `redeem` and ask for the order's real state.
 *
 * `executeRedemption` answering PENDING is NOT authoritative -> it only says "not terminal yet"
 * Without reconciliation a redemption PhonePe later settles is never observed -> the row keeps notified_at forever
 * current_period_end then stays in the past, the payer has no entitlement, and every run re-executes and logs PENDING
 * Two hours is well past the minutes a UPI debit takes -> a row still open here is webhook-lost or genuinely stuck
 * Reading order status does not interfere with PhonePe's own STANDARD retries -> they continue independently
 */
const RECONCILE_STUCK_AFTER_MS = 2 * 60 * 60 * 1000;

/** How far ahead Pass A looks for upcoming debits -> it must be >= the mandatory 24h pre-debit notice. */
const NOTIFY_WINDOW_HOURS = 24;

/**
 * Rows fetched per pass, per run.
 *
 * This is a SEQUENTIAL loop of PhonePe HTTP calls inside one invocation bounded by the cron duration limit
 * Unbounded, a backlog of a few hundred due rows kills the invocation partway -> survivors retry, but it never drains
 * And nothing surfaces that it is stuck -> so bound it AND log when the bound is hit
 */
const MAX_ROWS_PER_PASS = 200;

/**
 * Ceiling on outbound PhonePe calls per run, shared by both passes. Pass A costs 2/row, Pass B costs 1-3.
 *
 * A WALL-CLOCK guard, NOT a subrequest guard -> Workers Paid allows 10,000 subrequests per invocation
 * The binding limit is the 15-minute cron duration cap -> calls are sequential at ~0.7-1 s -> ~800 fit, 600 leaves headroom
 * CPU is not the constraint -> the loop awaits network -> a sub-hourly cron gets 30 s of CPU
 * Under the old 50-subrequest cap this budget never tripped -> the runtime killed every call past ~50 instead
 * The run then died partway down an oldest-first list -> fresh cohorts behind the failing head were never reached
 * That cost 30+ hours of zero conversions -> a run that stops on its OWN budget with a warning is the failure mode we want
 * Throughput also comes from cadence -> this trigger fires every 15 min -> one run need not do everything
 * Raise it only after a real tick logs the warning, and add concurrency first (4 max; Workers allow 6 connections)
 */
const MAX_PHONEPE_CALLS_PER_RUN = 600;

/**
 * PhonePe will not execute a redemption until 24h after its notify — the mandatory pre-debit notice.
 *
 * Executing earlier answers 400 SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED -> the call cannot succeed
 * Pass A re-notifies a recycled order and Pass B executed it in the SAME run -> three wasted subrequests per row per tick
 * A row inside this window is skipped with NO call at all
 */
const EXECUTE_AFTER_NOTIFY_MS = 24 * 60 * 60 * 1000;

/**
 * Subrequests a COMPLETED settle spends OUTSIDE the PhonePe calls — PostHog: one fetch plus a KV get and put.
 *
 * GA4 and Meta reported from here too, at 9 -> both are removed -> the charge drops with them
 * Uncounted, five settles in one tick blew the then-50-subrequest cap -> every row behind them got no redeem at all
 * Workers Paid retired that cap, but these are still real wall time on a 15-minute clock -> keep charging them
 * Charged against the same budget, the run stops cleanly with rows left rather than dying mid-row
 */
const SETTLE_REPORTER_SUBREQUESTS = 3;

/**
 * An order past PhonePe's 48h retry window can only settle through PhonePe's OWN retries — redeeming again is a 4xx.
 *
 * It is recycled at ~72h anyway, once its expireAt passes -> polling it every quarter hour buys nothing
 * A pile of stale PENDING orders once ate most of a tick's call budget -> fresh executes starved behind them
 * So reconcile these on the TOP-OF-HOUR tick only -> at most 45 min of extra latency on a row that waited two days
 * Age is measured from `notified_at`, which Pass A resets on a fresh order -> a recycled row still runs every tick
 */
const STALE_ORDER_MS = 48 * 60 * 60 * 1000;

/** True only on the quarter-hour tick that coincides with the top of the hour -> the once-an-hour work rides this. */
function isTopOfHourTick(): boolean {
  return new Date().getUTCMinutes() < 15;
}

/**
 * The earliest next_debit_at across all live subscriptions, cached in KV.
 * Before that instant minus the notify window this cron PROVABLY has no work -> it skips the DB entirely
 */
const NEXT_WORK_KEY = "autopay:next_work_at";

export async function runAutopayNotify(env: Env): Promise<void> {
  // ── Idle short-circuit ─────────────────────────────────────────────────────
  // This cron fires forever -> querying `subscriptions` unconditionally woke the Neon compute on every single tick
  // Neon bills compute-time and autosuspend is what keeps idle ticks near zero -> a marker makes an idle tick one KV read
  // Fail-open in every direction -> no marker, an unparseable marker or a KV error all fall through to the real query
  try {
    const cached = await env.KV.get(NEXT_WORK_KEY);
    if (cached !== null) {
      const nextWorkMs = Number(cached);
      if (Number.isFinite(nextWorkMs) && nextWorkMs > Date.now()) {
        console.log(
          `[autopay-notify] Nothing due before ${new Date(nextWorkMs).toISOString()} — skipping DB`,
        );
        return;
      }
    }
  } catch (err) {
    console.warn("[autopay-notify] idle-marker read failed, running anyway:", err);
  }

  const sql = getDb(env);
  let phonePeCalls = 0;
  const budgetLeft = (needed: number) =>
    phonePeCalls + needed <= MAX_PHONEPE_CALLS_PER_RUN;

  try {
    // Wake the pooled connection BEFORE the passes -> browse never touches the DB -> Neon suspends between ticks
    // The first query then lands on a severed socket and throws CONNECTION_CLOSED -> that kills the WHOLE scan
    // No row notified, no debit executed, and the next attempt a tick away -> one retry recovers it
    // A SECOND failure is real and propagates -> the caller logs it and the rows are picked up next tick
    try {
      await sql`SELECT 1`;
    } catch (err) {
      console.warn("[autopay-notify] cold connection — retrying once:", err);
      await sql`SELECT 1`;
    }

    const now = new Date();
    const notifyThreshold = new Date(now.getTime() + NOTIFY_WINDOW_HOURS * 60 * 60 * 1000);

    // ── Pass A: Notify ────────────────────────────────────────────────────────
    const toNotify = await sql`
      SELECT
        id,
        user_id,
        merchant_subscription_id,
        next_debit_at
      FROM subscriptions
      WHERE status IN ('trialing', 'active')
        AND next_debit_at <= ${notifyThreshold.toISOString()}
        AND notified_at IS NULL
      ORDER BY next_debit_at ASC
      LIMIT ${MAX_ROWS_PER_PASS}
    `;

    console.log(`[autopay-notify] Pass A — ${toNotify.length} subscriptions due for notify`);
    if (toNotify.length === MAX_ROWS_PER_PASS) {
      console.warn(
        `[autopay-notify] Pass A hit the ${MAX_ROWS_PER_PASS}-row cap — a backlog exists; ` +
        `remaining rows continue next run (soonest next_debit_at first)`,
      );
    }

    for (const row of toNotify) {
      const merchantSubId = row.merchant_subscription_id as string;
      const userId = row.user_id as string;

      if (!budgetLeft(2)) {
        console.warn(
          `[autopay-notify] Pass A stopping early — PhonePe call budget ` +
          `(${MAX_PHONEPE_CALLS_PER_RUN}) exhausted; rest retry next run`,
        );
        break;
      }

      try {
        phonePeCalls += 2; // status check + notify
        // PhonePe requires the mandate be verified ACTIVE before a notify
        const subStatus = await getSubscriptionStatus(env, merchantSubId);
        if (subStatus.state !== "ACTIVE") {
          // A bare `continue` here is what created the stuck-row loop -> the row keeps notified_at = NULL
          // It is then re-selected every tick, forever, for a mandate PhonePe already retired
          // A terminal state is a FINAL answer -> reconcile the row instead of re-asking
          if (TERMINAL_MANDATE_STATES.has(subStatus.state)) {
            await parkMandate(env, sql, row.id as string, "cancelled");
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state} at PhonePe — ` +
              `marked cancelled, next_debit_at cleared (access kept to current_period_end)`,
            );
          } else if (subStatus.state === "PAUSED") {
            await parkMandate(env, sql, row.id as string, "paused");
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is PAUSED at PhonePe — row marked paused`,
            );
          } else {
            // ACTIVATION_IN_PROGRESS and friends are genuinely in-flight -> they resolve on their own -> retry next tick
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state}, not ACTIVE — ` +
              `skipping notify, will retry next run`,
            );
          }
          continue;
        }

        const redemptionOrderId = buildMerchantOrderId(userId, "R");
        const notifyResult = await notifyRedemption(env, {
          merchantSubscriptionId: merchantSubId,
          merchantOrderId: redemptionOrderId,
          amountPaise: 19900, // ₹199
        });

        console.log(
          `[autopay-notify] Notified sub=${merchantSubId} orderId=${notifyResult.orderId} state=${notifyResult.state}`,
        );

        await sql`
          UPDATE subscriptions
          SET notified_at          = now(),
              redemption_order_id  = ${redemptionOrderId},
              updated_at           = now()
          WHERE id = ${row.id as string}
        `;

        // Log-only by design -> see sendUserNotification
        await sendUserNotification({
          userId,
          nextDebitAt: new Date(row.next_debit_at as string),
        });

      } catch (err) {
        // A 4xx is PhonePe's FINAL answer -> SUBSCRIPTION_NOT_FOUND is the one seen in the wild
        // Retrying it costs two PhonePe calls and a Neon wake per row per tick, forever, and never converges -> park it
        // Everything else — 5xx, 429, a dropped connection — is transient -> leaving notified_at NULL is right there
        if (err instanceof PhonePeApiError && err.isPermanent) {
          await parkMandate(env, sql, row.id as string, "cancelled", "rejected_by_phonepe");
          console.error(
            `[autopay-notify] Sub ${merchantSubId} rejected permanently by PhonePe ` +
            `(HTTP ${err.status}) — marked cancelled to stop the hourly retry loop. ` +
            `Access is kept to current_period_end. Body: ${err.body}`,
          );
        } else {
          console.error(`[autopay-notify] Notify failed for sub ${merchantSubId}:`, err);
          // Transient -> leave notified_at = NULL -> the next run re-selects and retries the row
        }
      }
    }

    // ── Pass B: Execute ───────────────────────────────────────────────────────
    const toExecute = await sql`
      SELECT
        id,
        user_id,
        status,
        merchant_subscription_id,
        redemption_order_id,
        retry_count,
        next_debit_at,
        notified_at,
        current_period_end
      FROM subscriptions
      WHERE notified_at IS NOT NULL
        AND notified_at <= ${new Date(now.getTime() - EXECUTE_AFTER_NOTIFY_MS).toISOString()}
        AND next_debit_at <= ${now.toISOString()}
        AND status IN ('trialing', 'active')
      ORDER BY next_debit_at ASC
      LIMIT ${MAX_ROWS_PER_PASS}
    `;

    console.log(`[autopay-notify] Pass B — ${toExecute.length} subscriptions due for execute`);
    if (toExecute.length === MAX_ROWS_PER_PASS) {
      console.warn(
        `[autopay-notify] Pass B hit the ${MAX_ROWS_PER_PASS}-row cap — backlog continues next run`,
      );
    }

    for (const row of toExecute) {
      const merchantSubId = row.merchant_subscription_id as string;
      const redemptionOrderId = row.redemption_order_id as string | null;

      if (!redemptionOrderId) {
        console.error(`[autopay-notify] No redemption_order_id for sub ${merchantSubId} — skipping execute`);
        continue;
      }

      // Belt to the SELECT's braces -> the 24h notify->execute window is re-checked -> no row can reach PhonePe early
      const notifiedAt = toDate(row.notified_at);
      if (notifiedAt !== null && Date.now() - notifiedAt.getTime() < EXECUTE_AFTER_NOTIFY_MS) {
        console.log(
          `[autopay-notify] Sub ${merchantSubId} notified ${Math.round((Date.now() - notifiedAt.getTime()) / 3_600_000)}h ago ` +
          `— inside PhonePe's 24h notify window, not executing yet`,
        );
        continue;
      }

      // A stale in-flight order is polled on the hour, never every tick -> see STALE_ORDER_MS
      if (
        notifiedAt !== null &&
        Date.now() - notifiedAt.getTime() > STALE_ORDER_MS &&
        !isTopOfHourTick()
      ) {
        console.log(
          `[autopay-notify] Sub ${merchantSubId} order is ${Math.round((Date.now() - notifiedAt.getTime()) / 3_600_000)}h old ` +
          `— past PhonePe's retry window, reconciled on the hourly tick only`,
        );
        continue;
      }

      if (!budgetLeft(1)) {
        console.warn(
          `[autopay-notify] Pass B stopping early — PhonePe call budget ` +
          `(${MAX_PHONEPE_CALLS_PER_RUN}) exhausted; rest retry next run`,
        );
        break;
      }

      const outcomeRow = {
        id: row.id as string,
        userId: row.user_id as string,
        retryCount: row.retry_count as number,
        merchantSubId,
        redemptionOrderId,
        // 'trialing' at settle time = the FIRST trial->paid conversion; 'active' = a renewal
        // Read from the SAME SELECT as the row -> a webhook racing this scan is harmless -> the KV marks dedupe
        priorStatus: row.status as string,
        // The dunning ladder's anchor -> NULL falls back to the due date -> an anchorless row still moves forward
        periodEnd: toDate(row.current_period_end) ?? toDate(row.next_debit_at),
      };
      const dueAt = toDate(row.next_debit_at);
      const overdueMs = dueAt === null ? 0 : Date.now() - dueAt.getTime();
      let settled = false;

      // ── Pass C first: the order's status is the only authority ───────────────
      // `redeem` is a TRIGGER, not an answer -> a UPI debit settles seconds AFTER PhonePe accepts the call
      // So its response is routinely non-terminal even as the money moves -> and a second redeem is then a 4xx
      // Reconciling AFTER the redeem attempt means the throw SKIPS it forever -> the row keeps notified_at
      // Pass A cannot re-select it either (it needs notified_at IS NULL) -> the payer sits in `trialing` having PAID
      // Two live subscribers were stranded that way for two days, orders COMPLETED and Neon untouched
      // So: ask BEFORE acting, and never let the answer depend on the redeem call succeeding
      if (overdueMs > RECONCILE_STUCK_AFTER_MS && budgetLeft(1)) {
        phonePeCalls += 1;
        const r = await reconcileFromOrder(env, sql, outcomeRow, overdueMs);
        settled = r.settled;
        if (settled) phonePeCalls += SETTLE_REPORTER_SUBREQUESTS;

        // The order outlived its window unsettled -> redeeming it again can only 4xx -> drop it for a fresh one
        // UNLESS the row is past the dunning wall -> an order that only ever dies non-terminally never advances the ladder
        // Without the wall such a row minted fresh orders without bound -> same business window as the last rung
        if (r.dead) {
          if (
            outcomeRow.periodEnd !== null &&
            Date.now() - outcomeRow.periodEnd.getTime() > DUNNING_WINDOW_MS
          ) {
            await sql`
              UPDATE subscriptions
              SET status              = 'expired',
                  notified_at         = NULL,
                  redemption_order_id = NULL,
                  updated_at          = now()
              WHERE id = ${outcomeRow.id}
            `;
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} unsettled ${Math.round(
                (Date.now() - outcomeRow.periodEnd.getTime()) / 86_400_000,
              )}d past period end — dunning window exhausted, expired`,
            );
            continue;
          }
          await recycleRedemption(sql, outcomeRow.id);
          console.warn(
            `[autopay-notify] Order ${redemptionOrderId} for sub ${merchantSubId} ` +
            `expired unsettled — cleared for re-notify, debit still owed`,
          );
          continue;
        }

        // PENDING means an attempt is ALREADY in flight and PhonePe owns the retry -> redeeming again is a 400
        // Skipping is not just a saved call -> the pointless attempt logged an ERROR every tick for a HEALTHY debit
        // A log where routine noise reads as failure is how the last stranding hid for two days
        // Only NOTIFIED — announced, never triggered — still needs the trigger
        if (r.state === "PENDING") {
          console.log(
            `[autopay-notify] Redemption already in flight for sub ${merchantSubId} ` +
            `(order PENDING) — PhonePe owns the retry, not re-redeeming`,
          );
          continue;
        }
      }

      if (settled) continue;

      if (!budgetLeft(1)) {
        console.warn(
          `[autopay-notify] Pass B stopping early — PhonePe call budget ` +
          `(${MAX_PHONEPE_CALLS_PER_RUN}) exhausted; rest retry next run`,
        );
        break;
      }

      try {
        phonePeCalls += 1;
        const execResult = await executeRedemption(env, redemptionOrderId);

        console.log(
          `[autopay-notify] Execute sub=${merchantSubId} state=${execResult.state} txn=${execResult.transactionId}`,
        );

        settled = await applyDebitOutcome(env, sql, execResult.state, outcomeRow);
        if (settled) phonePeCalls += SETTLE_REPORTER_SUBREQUESTS;

        if (!settled) {
          console.log(
            `[autopay-notify] Execute ${execResult.state} for sub ${merchantSubId} — ` +
            `settles asynchronously; next run reconciles from order status`,
          );
        }
      } catch (err) {
        // A throw is NOT evidence the debit failed -> the commonest cause is the order ALREADY settled
        // PhonePe then refuses the second redeem -> reconciling here is what recovers money we already took
        // DUPLICATE_TXN_REQUEST specifically means an attempt is in flight -> that is a HEALTHY debit
        // The reconcile-first branch normally catches those -> this is the belt-and-braces path inside the window
        // Log it as INFORMATION, never as an error -> normal traffic reading as failure is how a stranding hides
        const inFlight =
          err instanceof PhonePeApiError && err.body.includes("DUPLICATE_TXN_REQUEST");

        if (inFlight) {
          console.log(
            `[autopay-notify] Redemption already in flight for sub ${merchantSubId} ` +
            `— PhonePe owns the retry`,
          );
        } else {
          console.error(`[autopay-notify] Execute failed for sub ${merchantSubId}:`, err);
        }

        if (budgetLeft(1)) {
          phonePeCalls += 1;
          settled = (await reconcileFromOrder(env, sql, outcomeRow, overdueMs)).settled;
          if (settled) phonePeCalls += SETTLE_REPORTER_SUBREQUESTS;
        }

        // Still open after a FINAL rejection -> the mandate itself is usually gone, revoked by the user at their bank
        // Pass A cannot park it -> that pass only selects rows with notified_at IS NULL -> park it HERE
        // Otherwise it retries every tick, forever, against a mandate that will never debit
        // `inFlight` is excluded -> a duplicate proves the mandate works -> asking after its state learns nothing
        if (!settled && !inFlight && err instanceof PhonePeApiError && err.isPermanent && budgetLeft(1)) {
          phonePeCalls += 1;
          try {
            const subStatus = await getSubscriptionStatus(env, merchantSubId);
            if (TERMINAL_MANDATE_STATES.has(subStatus.state)) {
              await parkMandate(env, sql, outcomeRow.id, "cancelled");
              console.warn(
                `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state} at PhonePe — ` +
                `marked cancelled, debit abandoned (access kept to current_period_end)`,
              );
            }
          } catch (statusErr) {
            console.error(
              `[autopay-notify] Mandate status check failed for ${merchantSubId}:`,
              statusErr,
            );
          }
        }
      }
    }

    // ── Refresh the idle marker ───────────────────────────────────────────────
    // The next moment this cron could have work = the soonest next_debit_at among live rows, minus the notify window
    // Anything already due, or a row mid-flight with notified_at set, yields a past value -> store nothing, query next run
    await refreshIdleMarker(env, sql);

  } finally {
    // This connection may have been severed mid-flight and reconnected -> tearing down a dead socket can itself REJECT
    // Inside a `finally` that rejection REPLACES the result -> a scan that completed both passes reads as a failure
    await sql.end().catch(() => {});
  }
}

/**
 * Ask PhonePe for a redemption order's real state and apply it.
 *
 * `settled` -> the state was terminal and the row was updated
 * `dead` -> the read SUCCEEDED, the state is non-terminal, and the order is past its own `expireAt`
 * PhonePe stops retrying such an order -> nothing will ever settle it -> the row needs a fresh one
 * `dead` is only ever true off a SUCCESSFUL read -> a network blip cannot be mistaken for a dead order
 * Mistaking one would trigger a second charge -> a failed status call leaves both flags false
 * `state` is null when the read failed -> callers must never read null as "safe to skip"
 * Errors are swallowed deliberately -> this is the recovery path -> a failed read must not abort the scan
 */
async function reconcileFromOrder(
  env: Env,
  sql: ReturnType<typeof getDb>,
  row: {
    id: string;
    userId: string;
    retryCount: number;
    merchantSubId: string;
    redemptionOrderId: string;
    priorStatus: string;
    periodEnd: Date | null;
  },
  overdueMs: number,
): Promise<{ settled: boolean; dead: boolean; state: string | null }> {
  try {
    const order = await getOrderStatus(env, row.redemptionOrderId);
    console.log(
      `[autopay-notify] Reconcile sub=${row.merchantSubId} ` +
      `order=${row.redemptionOrderId} state=${order.state} ` +
      `(overdue ${Math.round(overdueMs / 3_600_000)}h)`,
    );
    const settled = await applyDebitOutcome(env, sql, order.state, row);
    const dead =
      !settled &&
      typeof order.expireAt === "number" &&
      order.expireAt > 0 &&
      Date.now() > order.expireAt;
    return { settled, dead, state: order.state };
  } catch (err) {
    console.error(
      `[autopay-notify] Reconcile failed for order ${row.redemptionOrderId}:`,
      err,
    );
    return { settled: false, dead: false, state: null };
  }
}

/**
 * Drop a dead redemption order so Pass A can issue a fresh one.
 * Clearing `notified_at` is what returns the row to Pass A's window -> that pass selects on `notified_at IS NULL`
 * `next_debit_at` is left ALONE -> the debit is still owed -> only the order is being replaced
 */
async function recycleRedemption(
  sql: ReturnType<typeof getDb>,
  subscriptionId: string,
): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET notified_at         = NULL,
        redemption_order_id = NULL,
        updated_at          = now()
    WHERE id = ${subscriptionId}
  `;
}

/**
 * Apply a terminal debit state to a subscription row. True = terminal and written; false = still open.
 *
 * Shared by Pass B's `redeem` response and Pass C's reconciled order status -> the two can never drift
 * A bug in one copy would otherwise grant a month the other refuses -> keep this the single writer
 * An unrecognised state returns false -> an unknown answer is "still open", never a settle
 */
async function applyDebitOutcome(
  env: Env,
  sql: ReturnType<typeof getDb>,
  state: string,
  row: {
    id: string;
    userId: string;
    retryCount: number;
    merchantSubId: string;
    redemptionOrderId: string;
    priorStatus: string;
    periodEnd: Date | null;
  },
): Promise<boolean> {
  if (state === "COMPLETED") {
    const nextPeriodEnd = addOneMonth(new Date());
    const settled = (await sql`
      UPDATE subscriptions
      SET status             = 'active',
          current_period_end = ${nextPeriodEnd.toISOString()},
          next_debit_at      = ${nextPeriodEnd.toISOString()},
          notified_at        = NULL,
          redemption_order_id = NULL,
          retry_count        = 0,
          updated_at         = now()
      WHERE id = ${row.id}
      RETURNING updated_at
    `) as unknown as { updated_at?: Date | string | null }[];
    // Referral reward on the referred user's FIRST paid debit -> the status<>'rewarded' guard makes a renewal a no-op
    await grantReferralReward(sql, row.userId);
    // NO ad-platform conversion is reported from the server -> GA4 `purchase` and Meta `Subscribe` are BOTH gone from here
    // A server-sent conversion is a SECOND source type for an event the app SDK also emits
    // One conversion action fed by two sources desynchronises attribution -> raw counts stay right, campaigns lag
    // `trial_started` / StartTrial — app-SDK, ONE source — is the only event campaigns bid on -> never add a second
    // PostHog stays -> it is product analytics, not an attribution source -> a server-sent event there costs nothing
    // FIRST trial->paid only ('trialing' at settle) -> a renewal ends no journey funnel
    // Fail-open and KV-deduped per transaction -> the webhook settling the same debit cannot double-report
    if (row.priorStatus === "trialing") {
      await reportPostHogFirstConversion(env, {
        userId: row.userId,
        transactionId: row.redemptionOrderId,
        amountPaise: 19900,
        occurredAt: settled[0]?.updated_at ?? null,
      });
    }
    return true;
  }

  if (state === "FAILED") {
    const retries = row.retryCount + 1;
    if (retries > RETRY_OFFSET_DAYS.length) {
      await sql`
        UPDATE subscriptions
        SET status      = 'expired',
            retry_count = ${retries},
            updated_at  = now()
        WHERE id = ${row.id}
      `;
      console.warn(
        `[autopay-notify] Sub ${row.merchantSubId} expired after ${retries} failed debits ` +
        `across the 45-day dunning window`,
      );
    } else {
      // Climb the ladder -> notified_at = NULL returns the row to Pass A's window
      // The pushed-out next_debit_at is what SPACES the attempts -> Pass A's SELECT looks one notify-window ahead
      // So Pass A re-notifies ~24h before the rung -> each retry carries its own fresh order and pre-debit notice
      const nextAttempt = nonPeakRetryAt(
        row.periodEnd ?? new Date(),
        RETRY_OFFSET_DAYS[retries - 1],
      );
      await sql`
        UPDATE subscriptions
        SET retry_count   = ${retries},
            notified_at   = NULL,
            next_debit_at = ${nextAttempt.toISOString()},
            updated_at    = now()
        WHERE id = ${row.id}
      `;
      console.log(
        `[autopay-notify] Sub ${row.merchantSubId} debit FAILED (attempt ${retries}) — ` +
        `next attempt ${nextAttempt.toISOString()} (day ${RETRY_OFFSET_DAYS[retries - 1]} of the ladder)`,
      );
    }
    return true;
  }

  return false;
}

/**
 * Cache "there is PROVABLY no autopay work before T" so an idle tick skips the DB.
 * Deliberately conservative -> any in-flight row, or any row already due, clears the marker instead
 */
async function refreshIdleMarker(
  env: Env,
  sql: ReturnType<typeof getDb>,
): Promise<void> {
  try {
    const rows = (await sql`
      SELECT
        min(next_debit_at) AS soonest,
        count(*) FILTER (WHERE notified_at IS NOT NULL) AS in_flight
      FROM subscriptions
      WHERE status IN ('trialing', 'active')
        AND next_debit_at IS NOT NULL
    `) as unknown as { soonest: unknown; in_flight: unknown }[];

    const inFlight = Number(rows[0]?.in_flight ?? 0);
    const soonestRaw = rows[0]?.soonest ?? null;
    if (inFlight > 0 || soonestRaw === null) {
      await env.KV.delete(NEXT_WORK_KEY);
      return;
    }

    const soonest = new Date(soonestRaw as string).getTime();
    if (!Number.isFinite(soonest)) {
      await env.KV.delete(NEXT_WORK_KEY);
      return;
    }
    // Work starts one notify-window BEFORE the debit itself -> the marker must be the earlier instant, not the due date
    const nextWorkMs = soonest - NOTIFY_WINDOW_HOURS * 60 * 60 * 1000;
    if (nextWorkMs <= Date.now()) {
      await env.KV.delete(NEXT_WORK_KEY);
      return;
    }
    // TTL is capped at the CRON PERIOD, never at nextWorkMs -> a subscription can activate between runs
    // Its webhook writes a next_debit_at this marker knows nothing about -> a days-long marker would skip a real debit
    // That trades a lost ₹199 and a broken subscription for a fraction of a cent of Neon compute -> never worth it
    // Capping at one period makes the worst case EXACTLY the un-cached behaviour
    await env.KV.put(NEXT_WORK_KEY, String(nextWorkMs), { expirationTtl: 3600 });
    console.log(
      `[autopay-notify] No work until ${new Date(nextWorkMs).toISOString()} — marker set`,
    );
  } catch (err) {
    // A marker we failed to write just means the next run does the full query -> never fail the scan over it
    console.warn("[autopay-notify] idle-marker refresh failed:", err);
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Take a subscription out of the autopay rotation WITHOUT touching entitlement.
 *
 * `next_debit_at = NULL` plus a status outside ('trialing','active') removes the row from BOTH passes' queries
 * That pair is what actually stops the loop -> changing only the status leaves it selectable
 * current_period_end is left ALONE -> 'cancelled' keeps premium to the end of the period already paid for
 * Parking is a BILLING decision, never a reason to strip bought access -> which is why we never park as 'expired'
 * Mirrored in Pakiza's workers/src/cron/autopay-notify.ts -> keep both in sync
 */
async function parkMandate(
  env: Env,
  sql: ReturnType<typeof getDb>,
  subscriptionId: string,
  status: "cancelled" | "paused",
  reason: SubscriptionCancelReason = "revoked_at_phonepe",
): Promise<void> {
  // Self-join so the PRIOR status rides back with the write -> `prior` is the pre-update row under Postgres SET semantics
  // The same shape the webhook's completed branch uses for its first-conversion gate -> keep the two identical
  const rows = (await sql`
    UPDATE subscriptions AS s
    SET status        = ${status},
        next_debit_at = NULL,
        notified_at   = NULL,
        updated_at    = now()
    FROM subscriptions AS prior
    WHERE s.id = ${subscriptionId} AND prior.id = s.id
    RETURNING s.user_id, s.merchant_subscription_id, prior.status AS prior_status,
              s.updated_at
  `) as unknown as {
    user_id: string;
    merchant_subscription_id: string | null;
    prior_status: string | null;
    updated_at?: Date | string | null;
  }[];
  if (status === "cancelled" && rows[0]) {
    await reportPostHogSubscriptionCancel(env, {
      userId: rows[0].user_id,
      merchantSubId: rows[0].merchant_subscription_id,
      reason,
      priorStatus: rows[0].prior_status,
      occurredAt: rows[0].updated_at ?? null,
    });
  }
}

function addOneMonth(date: Date): Date {
  const d = new Date(date);
  d.setMonth(d.getMonth() + 1);
  return d;
}

// ── User notification stub ─────────────────────────────────────────────────────

interface UserNotificationParams {
  userId: string;
  nextDebitAt: Date;
}

/**
 * Log-only BY DESIGN. Arul has no push channel -> reminders are on-device only and no screen may promise push.
 * PhonePe's own rails deliver the payer-facing pre-debit notice when the notify above succeeds -> a push here is redundant
 * If that ever reverses, the shape is FCM HTTP v1 plus an `fcm_token` column on `users`
 */
async function sendUserNotification(params: UserNotificationParams): Promise<void> {
  console.log(
    `[autopay-notify] TODO: push notify user=${params.userId}` +
    ` debitAt=${params.nextDebitAt.toISOString()}`,
  );
}
