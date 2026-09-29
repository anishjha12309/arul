import type { Env } from "../env.js";
import { getDb, toDate } from "../lib/db.js";
import {
  reportPostHogFirstConversion,
  reportPostHogSubscriptionCancel,
  type SubscriptionCancelReason,
} from "../lib/posthog.js";
import { grantReferralReward } from "../lib/referral.js";
import { rearmUnpausedSubscription } from "../lib/subscription-rearm.js";
import {
  notifyRedemption,
  executeRedemption,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantOrderId,
  merchantOf,
  PhonePeApiError,
} from "../lib/phonepe.js";

/** States PhonePe will never debit from again -> the answer is authoritative -> stop retrying the row, do not re-ask. */
const TERMINAL_MANDATE_STATES = new Set(["REVOKED", "CANCELLED", "EXPIRED", "FAILED"]);

const RETRY_OFFSET_DAYS = [2, 5, 10, 20, 32, 45];

const DUNNING_WINDOW_MS = 45 * 24 * 60 * 60 * 1000;

function nonPeakRetryAt(anchor: Date, offsetDays: number): Date {
  const due = new Date(anchor.getTime() + offsetDays * 24 * 60 * 60 * 1000);
  const aligned = new Date(due);
  aligned.setUTCHours(21, 30, 0, 0);
  if (aligned.getTime() < due.getTime()) aligned.setUTCDate(aligned.getUTCDate() + 1);
  return aligned;
}

/**
 * Two hours is well past the minutes a UPI debit takes -> a row still open here is webhook-lost or genuinely stuck
 * Reading order status does not interfere with PhonePe's own STANDARD retries -> they continue independently
 */
const RECONCILE_STUCK_AFTER_MS = 2 * 60 * 60 * 1000;

/** How far ahead Pass A looks for upcoming debits -> it must be >= the mandatory 24h pre-debit notice. */
const NOTIFY_WINDOW_HOURS = 24;

/**
 * This is a SEQUENTIAL loop of PhonePe HTTP calls inside one invocation bounded by the cron duration limit
 * Unbounded, a backlog of a few hundred due rows kills the invocation partway -> survivors retry, but it never drains
 * And nothing surfaces that it is stuck -> so bound it AND log when the bound is hit
 */
const MAX_ROWS_PER_PASS = 200;

/**
 * Raise it only after a real tick logs the warning, and add concurrency first (4 max; Workers allow 6 connections)
 */
const MAX_PHONEPE_CALLS_PER_RUN = 600;

const EXECUTE_AFTER_NOTIFY_MS = 24 * 60 * 60 * 1000;

/**
 * Subrequests a COMPLETED settle spends OUTSIDE the PhonePe calls — PostHog: one fetch plus a KV get and put.
 * Charged against the same budget, the run stops cleanly with rows left rather than dying mid-row
 */
const SETTLE_REPORTER_SUBREQUESTS = 3;

const STALE_ORDER_MS = 48 * 60 * 60 * 1000;

const MAX_PAUSED_RECHECK = 50;

/**
 * How long a proven mandate PhonePe rejects is left alone before Pass A asks again. Its next_debit_at moves past the
 * notify window by this much -> the row leaves Pass A's WHERE instead of taking a LIMIT slot every tick
 */
const REJECTED_RECHECK_MS = 6 * 60 * 60 * 1000;

function isTopOfHourTick(): boolean {
  return new Date().getUTCMinutes() < 15;
}

function nextTopOfHourMs(): number {
  const next = new Date();
  next.setUTCMinutes(0, 0, 0);
  next.setUTCHours(next.getUTCHours() + 1);
  return next.getTime();
}

/**
 * The earliest next_debit_at across all live subscriptions, cached in KV.
 * Before that instant minus the notify window this cron PROVABLY has no work -> it skips the DB entirely
 */
const NEXT_WORK_KEY = "autopay:next_work_at";

export async function runAutopayNotify(env: Env): Promise<void> {
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
  const budgetLeft = (needed: number) => phonePeCalls + needed <= MAX_PHONEPE_CALLS_PER_RUN;

  try {
    try {
      await sql`SELECT 1`;
    } catch (err) {
      console.warn("[autopay-notify] cold connection — retrying once:", err);
      await sql`SELECT 1`;
    }

    const now = new Date();
    const notifyThreshold = new Date(now.getTime() + NOTIFY_WINDOW_HOURS * 60 * 60 * 1000);

    const topOfHour = isTopOfHourTick();

    const staleFloor = topOfHour ? new Date(0) : new Date(now.getTime() - STALE_ORDER_MS);

    const toNotify = await sql`
      SELECT
        id,
        user_id,
        merchant_subscription_id,
        next_debit_at,
        debit_count,
        current_period_end
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
            console.warn(`[autopay-notify] Sub ${merchantSubId} is PAUSED at PhonePe — row marked paused`);
          } else {
            // ACTIVATION_IN_PROGRESS and friends are genuinely in-flight -> they resolve on their own -> retry next tick
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state}, not ACTIVE — ` +
                `skipping notify, will retry next run`,
            );
          }
          continue;
        }

        const redemptionOrderId = buildMerchantOrderId(userId, "R", merchantOf(merchantSubId));
        const notifyResult = await notifyRedemption(env, {
          merchantSubscriptionId: merchantSubId,
          merchantOrderId: redemptionOrderId,
          amountPaise: 19900,
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
        // A mandate that has already been debited does not vanish: a revoke reads REVOKED, not a 4xx. So a 4xx there
        // is a misroute, a PhonePe bug or a config slip, and one such fault answers for every due row at once ->
        // alarm and re-ask later; park only past the dunning wall. Never-debited rows keep the old park
        const periodEnd = toDate(row.current_period_end);
        const proven = Number(row.debit_count ?? 0) > 0;
        const pastWall = periodEnd !== null && Date.now() - periodEnd.getTime() > DUNNING_WINDOW_MS;
        if (err instanceof PhonePeApiError && err.isPermanent && proven && !pastWall) {
          const recheckAt = new Date(Date.now() + NOTIFY_WINDOW_HOURS * 60 * 60 * 1000 + REJECTED_RECHECK_MS);
          await sql`
            UPDATE subscriptions
            SET next_debit_at = ${recheckAt.toISOString()},
                updated_at    = now()
            WHERE id = ${row.id as string}
              AND status IN ('trialing', 'active')
          `;
          console.error(
            `[autopay-notify] ALARM — PhonePe rejected mandate ${merchantSubId}, which it confirmed before, ` +
              `with HTTP ${err.status}. NOT parked; re-asked after ${recheckAt.toISOString()}. ` +
              `Many of these at once = routing or PhonePe fault, not users. Body: ${err.body}`,
          );
        } else if (err instanceof PhonePeApiError && err.isPermanent) {
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
        current_period_end,
        upi_target_app
      FROM subscriptions
      WHERE notified_at IS NOT NULL
        AND notified_at <= ${new Date(now.getTime() - EXECUTE_AFTER_NOTIFY_MS).toISOString()}
        AND notified_at >= ${staleFloor.toISOString()}
        AND next_debit_at <= ${now.toISOString()}
        AND status IN ('trialing', 'active')
      -- Fresh debits first, then stuck ones least-recently-checked first: a PENDING check writes nothing, so
      -- oldest-due-first re-picked the same 200 in-flight orders every run and nothing newer was ever redeemed
      ORDER BY (next_debit_at < ${new Date(now.getTime() - RECONCILE_STUCK_AFTER_MS).toISOString()}) ASC,
               updated_at ASC
      LIMIT ${MAX_ROWS_PER_PASS}
    `;

    // The scope is named because the COUNT alone is ambiguous -> a quarter tick and an hourly tick
    // legitimately report different numbers off the same table, and the gap IS the stale pile
    console.log(
      `[autopay-notify] Pass B — ${toExecute.length} subscriptions due for execute ` +
        `(${topOfHour ? "all orders, incl. past PhonePe's retry window" : "fresh orders only, stale deferred to the hourly tick"})`,
    );
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

      if (notifiedAt !== null && Date.now() - notifiedAt.getTime() > STALE_ORDER_MS && !topOfHour) {
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
        // Which UPI app took the mandate at initiate -> rides to `subscription_active`; null predates the column
        upiTargetApp: (row.upi_target_app as string | null | undefined) ?? null,
        // The dunning ladder's anchor -> NULL falls back to the due date -> an anchorless row still moves forward
        periodEnd: toDate(row.current_period_end) ?? toDate(row.next_debit_at),
      };
      const dueAt = toDate(row.next_debit_at);
      const overdueMs = dueAt === null ? 0 : Date.now() - dueAt.getTime();
      let settled = false;

      // So: ask BEFORE acting, and never let the answer depend on the redeem call succeeding
      if (overdueMs > RECONCILE_STUCK_AFTER_MS && budgetLeft(1)) {
        phonePeCalls += 1;
        const r = await reconcileFromOrder(env, sql, outcomeRow, overdueMs);
        settled = r.settled;
        if (settled) phonePeCalls += SETTLE_REPORTER_SUBREQUESTS;

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

        if (r.state === "PENDING") {
          await touchInFlightRow(sql, outcomeRow.id, redemptionOrderId);
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
        const inFlight = err instanceof PhonePeApiError && err.body.includes("DUPLICATE_TXN_REQUEST");

        if (inFlight) {
          await touchInFlightRow(sql, outcomeRow.id, redemptionOrderId);
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

        // Pass A cannot park it -> that pass only selects rows with notified_at IS NULL -> park it HERE
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
            } else if (subStatus.state === "PAUSED") {
              // Same answer Pass A gives a paused mandate -> park it, and Pass D asks again hourly
              // Left in place it re-redeems every tick, forever, spending two calls on a 400 each time
              await parkMandate(env, sql, outcomeRow.id, "paused");
              console.warn(`[autopay-notify] Sub ${merchantSubId} is PAUSED at PhonePe — row marked paused`);
            } else {
              // Name the state -> a row that rejects every tick with a non-terminal mandate is otherwise invisible
              console.warn(
                `[autopay-notify] Sub ${merchantSubId} rejected the redeem but reads ${subStatus.state} at PhonePe — ` +
                  `left for the next tick`,
              );
            }
          } catch (statusErr) {
            console.error(`[autopay-notify] Mandate status check failed for ${merchantSubId}:`, statusErr);
          }
        }
      }
    }

    if (topOfHour && budgetLeft(1)) {
      const parkedPauses = await sql`
        SELECT id, merchant_subscription_id
        FROM subscriptions
        WHERE status = 'paused'
          AND merchant_subscription_id IS NOT NULL
        ORDER BY updated_at ASC
        LIMIT ${MAX_PAUSED_RECHECK}
      `;

      let checked = 0;
      let rearmed = 0;
      let cancelled = 0;
      let left = 0;

      for (const row of parkedPauses) {
        if (!budgetLeft(1)) {
          console.warn(
            `[autopay-notify] Pass D stopping early — PhonePe call budget ` +
              `(${MAX_PHONEPE_CALLS_PER_RUN}) exhausted; rest retry next hour`,
          );
          break;
        }

        const subscriptionId = row.id as string;
        const merchantSubId = row.merchant_subscription_id as string;
        phonePeCalls += 1;
        checked += 1;

        try {
          const subStatus = await getSubscriptionStatus(env, merchantSubId);
          if (subStatus.state === "ACTIVE") {
            await rearmUnpausedSubscription(sql, { subscriptionId });
            rearmed += 1;
            console.log(
              `[autopay-notify] Sub ${merchantSubId} is ACTIVE again at PhonePe — ` +
                `unpaused, debit clock rearmed`,
            );
          } else if (TERMINAL_MANDATE_STATES.has(subStatus.state)) {
            // Paused then killed -> the same park Pass B uses -> access still runs to current_period_end
            await parkMandate(env, sql, subscriptionId, "cancelled");
            cancelled += 1;
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state} at PhonePe — ` +
                `marked cancelled (access kept to current_period_end)`,
            );
          } else {
            left += 1;
            await touchPausedRow(sql, subscriptionId);
          }
        } catch (err) {
          // A failed read tells us nothing -> never park or restore on it -> but still rotate the cursor
          left += 1;
          await touchPausedRow(sql, subscriptionId);
          console.warn(`[autopay-notify] Pass D status check failed for ${merchantSubId}:`, err);
        }
      }

      // ONE line per run, whatever happened -> a per-row log for 50 unchanged rows every hour is how
      // the lines that DO matter get skimmed past
      console.log(
        `[autopay-notify] Pass D — ${checked} paused rows rechecked ` +
          `(${rearmed} rearmed, ${cancelled} cancelled, ${left} left paused)`,
      );
    }

    await refreshIdleMarker(env, sql);
  } finally {
    await sql.end().catch(() => {});
  }
}

/**
 * `settled` -> the state was terminal and the row was updated
 * `dead` -> the read SUCCEEDED, the state is non-terminal, and the order is past its own `expireAt`
 * `dead` is only ever true off a SUCCESSFUL read -> a network blip cannot be mistaken for a dead order
 * `state` is null when the read failed -> callers must never read null as "safe to skip"
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
    upiTargetApp?: string | null;
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
      !settled && typeof order.expireAt === "number" && order.expireAt > 0 && Date.now() > order.expireAt;
    return { settled, dead, state: order.state };
  } catch (err) {
    console.error(`[autopay-notify] Reconcile failed for order ${row.redemptionOrderId}:`, err);
    return { settled: false, dead: false, state: null };
  }
}

/**
 * `next_debit_at` is left ALONE -> the debit is still owed -> only the order is being replaced
 */
async function recycleRedemption(sql: ReturnType<typeof getDb>, subscriptionId: string): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET notified_at         = NULL,
        redemption_order_id = NULL,
        updated_at          = now()
    WHERE id = ${subscriptionId}
  `;
}

/** Sends a still-PENDING order to the back of Pass B's queue; the order guard skips a row settled meanwhile. */
async function touchInFlightRow(
  sql: ReturnType<typeof getDb>,
  subscriptionId: string,
  redemptionOrderId: string,
): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET updated_at = now()
    WHERE id = ${subscriptionId}
      AND redemption_order_id = ${redemptionOrderId}
  `;
}

/**
 * The updated_at trigger would do this by itself, but say it explicitly: this statement exists ONLY for it
 */
async function touchPausedRow(sql: ReturnType<typeof getDb>, subscriptionId: string): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET updated_at = now()
    WHERE id = ${subscriptionId}
      AND status = 'paused'
  `;
}

/**
 * Apply a terminal debit state to a subscription row. True = terminal and written; false = still open.
 * Shared by Pass B's `redeem` response and Pass C's reconciled order status -> the two can never drift
 * A bug in one copy would otherwise grant a month the other refuses -> keep this the single writer
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
    upiTargetApp?: string | null;
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
          first_debit_at     = COALESCE(first_debit_at, now()),
          debit_count        = debit_count + 1,
          paid_paise         = paid_paise + 19900,
          updated_at         = now()
      WHERE id = ${row.id}
        AND redemption_order_id = ${row.redemptionOrderId}
      RETURNING updated_at
    `) as unknown as { updated_at?: Date | string | null }[];
    // No row -> the webhook settled this order first (it clears redemption_order_id) and already counted the
    // ₹199, granted the reward and reported -> a second write double-counted debit_count and paid_paise
    if (settled.length === 0) {
      console.log(
        `[autopay-notify] Order ${row.redemptionOrderId} for sub ${row.merchantSubId} already settled by the webhook`,
      );
      return true;
    }
    // Referral reward on the referred user's FIRST paid debit -> the status<>'rewarded' guard makes a renewal a no-op
    await grantReferralReward(sql, row.userId);
    // FIRST trial->paid only ('trialing' at settle) -> a renewal ends no journey funnel
    // Fail-open and KV-deduped per transaction -> the webhook settling the same debit cannot double-report
    if (row.priorStatus === "trialing") {
      await reportPostHogFirstConversion(env, {
        userId: row.userId,
        transactionId: row.redemptionOrderId,
        amountPaise: 19900,
        occurredAt: settled[0]?.updated_at ?? null,
        targetApp: row.upiTargetApp ?? null,
        merchantSubId: row.merchantSubId,
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
      const nextAttempt = nonPeakRetryAt(row.periodEnd ?? new Date(), RETRY_OFFSET_DAYS[retries - 1]);
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
async function refreshIdleMarker(env: Env, sql: ReturnType<typeof getDb>): Promise<void> {
  try {
    const rows = (await sql`
      SELECT
        min(next_debit_at) FILTER (
          WHERE status IN ('trialing', 'active') AND next_debit_at IS NOT NULL
        ) AS soonest,
        count(*) FILTER (
          WHERE status IN ('trialing', 'active') AND notified_at IS NOT NULL
        ) AS in_flight,
        count(*) FILTER (
          WHERE status = 'paused' AND merchant_subscription_id IS NOT NULL
        ) AS paused_rechecks
      FROM subscriptions
    `) as unknown as { soonest: unknown; in_flight: unknown; paused_rechecks: unknown }[];

    const inFlight = Number(rows[0]?.in_flight ?? 0);
    const soonestRaw = rows[0]?.soonest ?? null;
    const pausedRechecks = Number(rows[0]?.paused_rechecks ?? 0);
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
    const nextWorkMs = Math.min(
      soonest - NOTIFY_WINDOW_HOURS * 60 * 60 * 1000,
      pausedRechecks > 0 ? nextTopOfHourMs() : Infinity,
    );
    if (nextWorkMs <= Date.now()) {
      await env.KV.delete(NEXT_WORK_KEY);
      return;
    }
    // TTL is capped at the CRON PERIOD, never at nextWorkMs -> a subscription can activate between runs
    // Its webhook writes a next_debit_at this marker knows nothing about -> a days-long marker would skip a real debit
    // That trades a lost ₹199 and a broken subscription for a fraction of a cent of Neon compute -> never worth it
    await env.KV.put(NEXT_WORK_KEY, String(nextWorkMs), { expirationTtl: 3600 });
    console.log(`[autopay-notify] No work until ${new Date(nextWorkMs).toISOString()} — marker set`);
  } catch (err) {
    // A marker we failed to write just means the next run does the full query -> never fail the scan over it
    console.warn("[autopay-notify] idle-marker refresh failed:", err);
  }
}

/**
 * Take a subscription out of the autopay rotation WITHOUT touching entitlement.
 * `next_debit_at = NULL` plus a status outside ('trialing','active') removes the row from BOTH passes' queries
 * That pair is what actually stops the loop -> changing only the status leaves it selectable
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

interface UserNotificationParams {
  userId: string;
  nextDebitAt: Date;
}

/**
 * Log-only BY DESIGN, and it stays that way now that the app HAS a push channel (docs/push.md).
 * PhonePe's own rails deliver the payer-facing pre-debit notice when the notify above succeeds -> a push here is redundant,
 * and a debit reminder is a payment follow-up, not a campaign -> it does not belong in the CMS's composer either
 */
async function sendUserNotification(params: UserNotificationParams): Promise<void> {
  console.log(
    `[autopay-notify] TODO: push notify user=${params.userId}` +
      ` debitAt=${params.nextDebitAt.toISOString()}`,
  );
}
