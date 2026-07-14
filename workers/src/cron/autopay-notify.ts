/**
 * Autopay cron — PhonePe Standard Checkout v2 (OAuth / O-Bearer)
 *
 * Required by CLAUDE.md §8 gotcha #5:
 *   "MUST notify user 24h before each debit (pg_cron Edge Function)"
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
 * NOTE: Notification delivery to users (FCM/push) is a TODO stub below.
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  notifyRedemption,
  executeRedemption,
  getSubscriptionStatus,
  buildMerchantOrderId,
} from "../lib/phonepe.js";

/** Maximum failed execute attempts before we expire the subscription. */
const MAX_RETRIES = 5;

/** How far ahead to look for upcoming debits when deciding to notify. */
const NOTIFY_WINDOW_HOURS = 24;

export async function runAutopayNotify(env: Env): Promise<void> {
  const sql = getDb(env);

  try {
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
    `;

    console.log(`[autopay-notify] Pass A — ${toNotify.length} subscriptions due for notify`);

    for (const row of toNotify) {
      const merchantSubId = row.merchant_subscription_id as string;
      const userId = row.user_id as string;

      try {
        // Must verify ACTIVE before notifying (PhonePe docs requirement)
        const subStatus = await getSubscriptionStatus(env, merchantSubId);
        if (subStatus.state !== "ACTIVE") {
          console.warn(
            `[autopay-notify] Sub ${merchantSubId} is ${subStatus.state}, not ACTIVE — skipping notify`,
          );
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

        // Stub: notify the user via push/FCM
        await sendUserNotification({
          userId,
          nextDebitAt: new Date(row.next_debit_at as string),
        });

      } catch (err) {
        console.error(`[autopay-notify] Notify failed for sub ${merchantSubId}:`, err);
        // Leave notified_at = NULL → will retry on next cron run
      }
    }

    // ── Pass B: Execute ───────────────────────────────────────────────────────
    const toExecute = await sql`
      SELECT
        id,
        user_id,
        merchant_subscription_id,
        redemption_order_id,
        retry_count
      FROM subscriptions
      WHERE notified_at IS NOT NULL
        AND next_debit_at <= ${now.toISOString()}
        AND status IN ('trialing', 'active')
    `;

    console.log(`[autopay-notify] Pass B — ${toExecute.length} subscriptions due for execute`);

    for (const row of toExecute) {
      const merchantSubId = row.merchant_subscription_id as string;
      const redemptionOrderId = row.redemption_order_id as string | null;

      if (!redemptionOrderId) {
        console.error(`[autopay-notify] No redemption_order_id for sub ${merchantSubId} — skipping execute`);
        continue;
      }

      try {
        const execResult = await executeRedemption(env, redemptionOrderId);

        console.log(
          `[autopay-notify] Execute sub=${merchantSubId} state=${execResult.state} txn=${execResult.transactionId}`,
        );

        if (execResult.state === "COMPLETED") {
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
            WHERE id = ${row.id as string}
          `;
          // Referral reward on the referred user's first paid debit. Idempotent:
          // the status<>'rewarded' guard means monthly renewals never re-credit.
          await grantReferralReward(sql, row.user_id as string);
        } else if (execResult.state === "FAILED") {
          const retries = (row.retry_count as number) + 1;
          if (retries >= MAX_RETRIES) {
            await sql`
              UPDATE subscriptions
              SET status      = 'expired',
                  retry_count = ${retries},
                  updated_at  = now()
              WHERE id = ${row.id as string}
            `;
            console.warn(`[autopay-notify] Sub ${merchantSubId} expired after ${retries} failures`);
          } else {
            await sql`
              UPDATE subscriptions
              SET retry_count = ${retries},
                  notified_at = NULL,
                  updated_at  = now()
              WHERE id = ${row.id as string}
            `;
            // notified_at = NULL allows pass A to re-notify on the next cron run
          }
        } else {
          // PENDING — PhonePe STANDARD strategy is still retrying; leave state alone
          console.log(`[autopay-notify] Execute PENDING for sub ${merchantSubId} — waiting for STANDARD retry`);
        }

      } catch (err) {
        console.error(`[autopay-notify] Execute failed for sub ${merchantSubId}:`, err);
        // Leave state; will be retried next hour
      }
    }

  } finally {
    await sql.end();
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

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
 * Notify the user that a debit is imminent.
 *
 * TODO: implement with FCM or another push provider.
 * Steps:
 *   1. Add a `fcm_token` column to the `users` table.
 *   2. Store the token from the Flutter app on notification permission grant.
 *   3. Call the FCM HTTP v1 API:
 *      POST https://fcm.googleapis.com/v1/projects/{projectId}/messages:send
 *      Authorization: Bearer <google-service-account-token>
 *   4. Add FIREBASE_PROJECT_ID and a service-account key as Worker secrets.
 */
async function sendUserNotification(params: UserNotificationParams): Promise<void> {
  console.log(
    `[autopay-notify] TODO: push notify user=${params.userId}` +
    ` debitAt=${params.nextDebitAt.toISOString()}`,
  );
}
