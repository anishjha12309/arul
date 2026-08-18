/**
 * Autopay cron — PhonePe Standard Checkout v2 (OAuth / O-Bearer)
 *
 * Required by CLAUDE.md §8 gotcha #4:
 *   "notify user 24h before each debit (hourly cron)"
 * Implemented as a Cloudflare Worker cron trigger (not a DB-scheduled job).
 *
 * Per PhonePe docs:
 *   - The Notify API must be called BEFORE the debit date.
 *   - The Execute (redeem) API is called AT or AFTER the debit date.
 *   - redemptionRetryStrategy = "STANDARD" → PhonePe auto-retries up to 48h.
 *
 * This cron runs hourly ("0 * * * *" in wrangler.toml) and performs two passes:
 *
 *   Pass A — NOTIFY:
 *     Subscriptions with status IN ('trialing', 'active')
 *       AND next_debit_at <= now() + 24h
 *       AND notified_at IS NULL
 *     → verify ACTIVE via PhonePe subscription status API
 *     → call POST /subscriptions/v2/notify
 *     → set notified_at = now(), redemption_order_id = new merchantOrderId
 *
 *   Pass B — EXECUTE:
 *     Subscriptions with notified_at IS NOT NULL
 *       AND next_debit_at <= now()
 *     → call POST /subscriptions/v2/redeem
 *     → on COMPLETED: status='active', current_period_end=+1month, next_debit_at=+1month, notified_at=NULL
 *     → on FAILED:    increment retry_count; if retry_count >= MAX_RETRIES, mark expired
 *     → on PENDING:   leave as-is (PhonePe is still processing / retrying via STANDARD strategy)
 *
 * NOTE: sendUserNotification below is a log-only stub BY DESIGN — Arul has no
 * push channel (docs/notifications.md); PhonePe's notify call delivers the
 * payer-facing pre-debit notice through its own rails.
 */

import type { Env } from "../env.js";
import { getDb, toDate } from "../lib/db.js";
import { reportServerPurchase } from "../lib/ga4.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  notifyRedemption,
  executeRedemption,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantOrderId,
  PhonePeApiError,
} from "../lib/phonepe.js";

/**
 * Mandate states from which PhonePe will never debit again. Seeing one of these
 * is authoritative — the mandate is gone at their end, so a row still pointing
 * at it must stop being retried.
 */
const TERMINAL_MANDATE_STATES = new Set([
  "REVOKED",
  "CANCELLED",
  "EXPIRED",
  "FAILED",
]);

/** Maximum failed execute attempts before we expire the subscription. */
const MAX_RETRIES = 5;

/**
 * How long past its due date a debit may sit un-settled before we stop trusting
 * `redeem` and ask the gateway for the order's real state.
 *
 * `executeRedemption` answering PENDING is not authoritative — it only says "not
 * terminal yet". Without a reconciliation, a redemption that PhonePe later
 * settles (or abandons) is never observed: the row keeps its `notified_at` and
 * `redemption_order_id`, `current_period_end` stays in the past, the user has no
 * entitlement, and every subsequent run re-executes and logs PENDING again
 * forever. Nothing in the cron ever called `getOrderStatus`.
 *
 * Two hours is well past the minutes a UPI debit takes to settle, so a row still
 * un-settled here is either webhook-lost or genuinely stuck — both cases the
 * gateway can answer. PhonePe's own STANDARD retries continue independently;
 * reading order status does not interfere with them.
 */
const RECONCILE_STUCK_AFTER_MS = 2 * 60 * 60 * 1000;

/** How far ahead to look for upcoming debits when deciding to notify. */
const NOTIFY_WINDOW_HOURS = 24;

/**
 * Rows fetched per pass, per run.
 *
 * This cron is a SEQUENTIAL loop making PhonePe HTTP calls per row, inside a
 * single scheduled invocation bounded by the Workers subrequest cap and cron
 * duration. Unbounded, a backlog of a few hundred due subscribers would simply
 * kill the invocation partway — safe (survivors retry next hour) but it never
 * drains and nothing surfaces that it is stuck. Bounded + logged instead.
 */
const MAX_ROWS_PER_PASS = 200;

/**
 * Ceiling on outbound PhonePe calls per run, shared across both passes.
 * Pass A costs 2 per row (status check + notify), Pass B costs 1 (redeem).
 */
const MAX_PHONEPE_CALLS_PER_RUN = 400;

/**
 * KV key caching the earliest next_debit_at across all live subscriptions.
 * While that instant is still in the future minus the notify window, this cron
 * provably has nothing to do and can skip the DB entirely.
 */
const NEXT_WORK_KEY = "autopay:next_work_at";

export async function runAutopayNotify(env: Env): Promise<void> {
  // ── Idle short-circuit ─────────────────────────────────────────────────────
  // WHY: this cron runs hourly forever and used to query `subscriptions`
  // unconditionally, so it woke the Neon compute every single hour whether or
  // not any debit was due. Neon bills by compute-time and autosuspend is what
  // keeps idle hours near zero cost. A cached "nothing is due before T" marker
  // makes an idle hour cost one KV read instead of a cold start.
  //
  // Fail-open in every direction: no marker, unparseable marker, or KV error
  // all fall through to the real query.
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
    // Wake the pooled connection before the passes.
    //
    // This Worker idles for hours at a time — browse never touches the DB
    // (CLAUDE.md: the feed is edge-cached catalog JSON) — so Neon suspends and
    // Hyperdrive's pooled connection goes stale. The first query of a cron run
    // then lands on a severed socket and throws CONNECTION_CLOSED, which kills
    // the whole scan: no row is notified, no debit is executed, and the next
    // attempt is an hour away.
    //
    // Observed in Pakiza production 2026-07-27T02:00:03Z (same worker shape,
    // same idle profile as this fork): its catalog rebuild retried onto a fresh
    // connection and recovered, while its autopay scan produced no output at
    // all.
    //
    // A second failure is real and propagates — the caller logs it and the row
    // is picked up next hour.
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
        // Must verify ACTIVE before notifying (PhonePe docs requirement)
        const subStatus = await getSubscriptionStatus(env, merchantSubId);
        if (subStatus.state !== "ACTIVE") {
          // A bare `continue` here is what created the stuck-row loop: the row
          // keeps notified_at = NULL, so it is re-selected next hour, forever,
          // for a mandate PhonePe has already retired. Terminal states are a
          // final answer — reconcile the row instead of re-asking hourly.
          if (TERMINAL_MANDATE_STATES.has(subStatus.state)) {
            await parkMandate(sql, row.id as string, "cancelled");
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state} at PhonePe — ` +
              `marked cancelled, next_debit_at cleared (access kept to current_period_end)`,
            );
          } else if (subStatus.state === "PAUSED") {
            await parkMandate(sql, row.id as string, "paused");
            console.warn(
              `[autopay-notify] Sub ${merchantSubId} is PAUSED at PhonePe — row marked paused`,
            );
          } else {
            // ACTIVATION_IN_PROGRESS and friends are genuinely in-flight; these
            // DO resolve on their own, so retrying next hour is correct.
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

        // Log-only by design — see sendUserNotification.
        await sendUserNotification({
          userId,
          nextDebitAt: new Date(row.next_debit_at as string),
        });

      } catch (err) {
        // A 4xx is PhonePe's final answer (SUBSCRIPTION_NOT_FOUND is the one
        // seen in the wild). Retrying it hourly forever costs two PhonePe calls
        // and a Neon wake per row per hour and never converges, so park the row
        // instead. Everything else — 5xx, 429, a dropped connection — really is
        // transient, and for those leaving notified_at = NULL to retry next run
        // is the correct behaviour.
        if (err instanceof PhonePeApiError && err.isPermanent) {
          await parkMandate(sql, row.id as string, "cancelled");
          console.error(
            `[autopay-notify] Sub ${merchantSubId} rejected permanently by PhonePe ` +
            `(HTTP ${err.status}) — marked cancelled to stop the hourly retry loop. ` +
            `Access is kept to current_period_end. Body: ${err.body}`,
          );
        } else {
          console.error(`[autopay-notify] Notify failed for sub ${merchantSubId}:`, err);
          // Transient — leave notified_at = NULL so the next cron run retries.
        }
      }
    }

    // ── Pass B: Execute ───────────────────────────────────────────────────────
    const toExecute = await sql`
      SELECT
        id,
        user_id,
        merchant_subscription_id,
        redemption_order_id,
        retry_count,
        next_debit_at
      FROM subscriptions
      WHERE notified_at IS NOT NULL
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
      };
      const dueAt = toDate(row.next_debit_at);
      const overdueMs = dueAt === null ? 0 : Date.now() - dueAt.getTime();
      let settled = false;

      // ── Pass C first: the order's status is the only authority ───────────────
      //
      // `redeem` is a TRIGGER, not an answer. A UPI debit settles seconds after
      // PhonePe accepts the call, so the redeem response is routinely
      // non-terminal even when the money is about to move — and once it has
      // moved, redeeming the same order again is a 4xx.
      //
      // Reconciling AFTER the redeem attempt (which is where this used to live,
      // inside the try, below the throwing call) means the throw skips it
      // forever: the row keeps notified_at + redemption_order_id, Pass A won't
      // re-select it (notified_at IS NULL), and the user sits in `trialing` past
      // their period end having already PAID. Two live subscribers were stranded
      // that way for two days (prod 2026-08-16 and 08-17, ₹199 each, PhonePe
      // orders COMPLETED, Neon untouched). So: ask before acting, and never let
      // the answer depend on the redeem call succeeding.
      if (overdueMs > RECONCILE_STUCK_AFTER_MS && budgetLeft(1)) {
        phonePeCalls += 1;
        const r = await reconcileFromOrder(env, sql, outcomeRow, overdueMs);
        settled = r.settled;

        // Order outlived its window and never settled — redeeming it again can
        // only 4xx. Drop it so Pass A mints a fresh one instead of looping.
        if (r.dead) {
          await recycleRedemption(sql, outcomeRow.id);
          console.warn(
            `[autopay-notify] Order ${redemptionOrderId} for sub ${merchantSubId} ` +
            `expired unsettled — cleared for re-notify, debit still owed`,
          );
          continue;
        }

        // PENDING means a redemption attempt is ALREADY in flight and PhonePe
        // has taken over the retry: redeeming again answers 400
        // DUPLICATE_TXN_REQUEST ("not allowed for PHONEPE_CONTROLLED retry
        // strategy"). Skipping is not just a saved call — the pointless attempt
        // logged an ERROR every hour for a debit that was perfectly healthy, and
        // a log where routine noise looks like failure is how the last stranding
        // went unnoticed for two days. Only NOTIFIED (announced, never
        // triggered) still needs the trigger.
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

        if (!settled) {
          console.log(
            `[autopay-notify] Execute ${execResult.state} for sub ${merchantSubId} — ` +
            `settles asynchronously; next run reconciles from order status`,
          );
        }
      } catch (err) {
        // A throw is NOT evidence the debit failed. The commonest cause is the
        // opposite: the order already settled and PhonePe refuses a second
        // redeem. Reconciling here is what recovers the money we already took.
        //
        // DUPLICATE_TXN_REQUEST specifically means "an attempt is already in
        // flight" — a HEALTHY debit. The reconcile-first branch above normally
        // catches those before we get here; this is the belt-and-braces path for
        // a row still inside the reconcile window. Log it as information, never
        // as an error: a log where normal traffic reads as failure is what let
        // the last stranding hide in plain sight for two days.
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
        }

        // Still open after a FINAL rejection: the mandate itself is usually gone
        // (revoked by the user at their bank), and Pass A cannot park it because
        // it only selects rows with notified_at IS NULL. Park it here or it
        // retries hourly forever against a mandate that will never debit.
        //
        // `inFlight` is excluded: a duplicate proves the mandate is working, so
        // asking after its state would burn a call to learn nothing.
        if (!settled && !inFlight && err instanceof PhonePeApiError && err.isPermanent && budgetLeft(1)) {
          phonePeCalls += 1;
          try {
            const subStatus = await getSubscriptionStatus(env, merchantSubId);
            if (TERMINAL_MANDATE_STATES.has(subStatus.state)) {
              await parkMandate(sql, outcomeRow.id, "cancelled");
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
    // Earliest moment this cron could next have work = the soonest next_debit_at
    // among live subscriptions, minus the notify window. Anything already due
    // (or a row mid-flight with notified_at set) yields a past/absent value, so
    // we store nothing and the next run queries normally.
    await refreshIdleMarker(env, sql);

  } finally {
    // Swallow end()'s own rejection. This connection may have been severed
    // mid-flight and reconnected; tearing down a socket that is already gone
    // can itself reject, and inside a `finally` that rejection REPLACES the
    // result — turning a scan that fully completed both passes into a failed
    // promise the caller reports as an error.
    await sql.end().catch(() => {});
  }
}

/**
 * Ask PhonePe for a redemption order's real state and apply it.
 *
 * `settled` — the state was terminal and the row was updated.
 * `dead`    — the read SUCCEEDED, the state is non-terminal, and the order is
 *             past its own `expireAt`. PhonePe stops retrying such an order, so
 *             nothing will ever settle it and the row needs a fresh one.
 *             Only ever true off a successful read: a failed status call leaves
 *             both flags false, so a network blip can never be mistaken for a
 *             dead order and trigger a second charge.
 * `state`   — the observed order state, or null when the read failed. Callers
 *             use it to decide whether a redeem is still worth attempting; null
 *             must therefore never be read as "safe to skip".
 *
 * Deliberately swallows its own errors: this runs on the recovery path, and a
 * status read that fails must never mask the debit outcome or abort the scan.
 * Reading order status does not interfere with PhonePe's own STANDARD retries.
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
 *
 * Clearing `notified_at` is what puts the row back in Pass A's window (it
 * selects on `notified_at IS NULL`), which re-notifies and mints a new order id.
 * `next_debit_at` is left alone — the debit is still owed.
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
 * Apply a terminal debit state to a subscription row.
 *
 * Shared by Pass B (the `redeem` response) and Pass C (the reconciled order
 * status) so the two can never drift — a bug in one would otherwise grant a
 * month the other refuses.
 *
 * @returns true when the state was terminal and the row was updated; false for
 *          PENDING or any state we do not recognise, meaning "still open".
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
  },
): Promise<boolean> {
  if (state === "COMPLETED") {
    const nextPeriodEnd = addOneMonth(new Date());
    await sql`
      UPDATE subscriptions
      SET status             = 'active',
          current_period_end = ${nextPeriodEnd.toISOString()},
          next_debit_at      = ${nextPeriodEnd.toISOString()},
          notified_at        = NULL,
          redemption_order_id = NULL,
          retry_count        = 0,
          updated_at         = now()
      WHERE id = ${row.id}
    `;
    // Referral reward on the referred user's first paid debit. Idempotent:
    // the status<>'rewarded' guard means monthly renewals never re-credit.
    await grantReferralReward(sql, row.userId);
    // App-closed settle → report `purchase` server-side (GA4 MP). Same
    // transaction id as the webhook path, so whichever lands second dedupes.
    // Fail-open — never blocks the grant above.
    await reportServerPurchase(env, sql, {
      userId: row.userId,
      transactionId: row.redemptionOrderId,
      amountPaise: 19900,
    });
    return true;
  }

  if (state === "FAILED") {
    const retries = row.retryCount + 1;
    if (retries >= MAX_RETRIES) {
      await sql`
        UPDATE subscriptions
        SET status      = 'expired',
            retry_count = ${retries},
            updated_at  = now()
        WHERE id = ${row.id}
      `;
      console.warn(`[autopay-notify] Sub ${row.merchantSubId} expired after ${retries} failures`);
    } else {
      await sql`
        UPDATE subscriptions
        SET retry_count = ${retries},
            notified_at = NULL,
            updated_at  = now()
        WHERE id = ${row.id}
      `;
      // notified_at = NULL allows pass A to re-notify on the next cron run
    }
    return true;
  }

  return false;
}

/**
 * Cache "there is provably no autopay work before T" so idle hours skip the DB.
 * Deliberately conservative: any in-flight row (notified_at set) or any row
 * already due clears the marker so the next run does the real work.
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
    // Work starts one notify-window BEFORE the debit itself.
    const nextWorkMs = soonest - NOTIFY_WINDOW_HOURS * 60 * 60 * 1000;
    if (nextWorkMs <= Date.now()) {
      await env.KV.delete(NEXT_WORK_KEY);
      return;
    }
    // TTL is deliberately capped at the CRON PERIOD, never at nextWorkMs.
    // A subscription that activates between runs writes its own next_debit_at
    // via the webhook, and this marker knows nothing about it. Letting the
    // marker live for days would risk skipping a real debit — a lost ₹199 and a
    // broken subscription — to save a fraction of a cent of Neon compute.
    // Capping at one hour means the worst case is EXACTLY today's behaviour.
    await env.KV.put(NEXT_WORK_KEY, String(nextWorkMs), { expirationTtl: 3600 });
    console.log(
      `[autopay-notify] No work until ${new Date(nextWorkMs).toISOString()} — marker set`,
    );
  } catch (err) {
    // A marker we failed to write just means the next run does the full query.
    console.warn("[autopay-notify] idle-marker refresh failed:", err);
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Take a subscription out of the autopay rotation without touching entitlement.
 *
 * `next_debit_at = NULL` plus a status outside ('trialing','active') removes the
 * row from BOTH passes' queries, which is what actually stops the hourly loop.
 *
 * current_period_end is deliberately left alone: 'cancelled' keeps premium to
 * the end of the period the user already paid for. Parking a row is a billing
 * decision, never a reason to strip access someone has bought — which is also
 * why we never park as 'expired' here.
 *
 * Mirrored in Pakiza (workers/src/cron/autopay-notify.ts) — keep both in sync.
 */
async function parkMandate(
  sql: ReturnType<typeof getDb>,
  subscriptionId: string,
  status: "cancelled" | "paused",
): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET status        = ${status},
        next_debit_at = NULL,
        notified_at   = NULL,
        updated_at    = now()
    WHERE id = ${subscriptionId}
  `;
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
 * Log-only BY DESIGN. Arul deliberately has no push channel — reminders are
 * on-device only and no screen may promise push (docs/notifications.md) — and
 * the payer-facing pre-debit notice is delivered by PhonePe's own rails when
 * the notify call above succeeds, so an app push here would be redundant.
 * If that decision ever reverses, the shape is FCM HTTP v1 plus an
 * `fcm_token` column on `users`.
 */
async function sendUserNotification(params: UserNotificationParams): Promise<void> {
  console.log(
    `[autopay-notify] TODO: push notify user=${params.userId}` +
    ` debitAt=${params.nextDebitAt.toISOString()}`,
  );
}
