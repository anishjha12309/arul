/**
 * Internal routes — operator / cron only.
 *
 *   POST /internal/build-catalog
 *     Auth: Authorization: Bearer <CATALOG_BUILD_SECRET>
 *     Rebuilds R2 catalog JSON from Neon. Called by:
 *       - The hourly CRON (via the scheduled handler in index.ts)
 *       - Manual operator trigger (curl with the bearer secret)
 *     Supports optional { scope } body to rebuild a single scope.
 *
 *   POST /internal/run-redemptions
 *     Auth: Authorization: Bearer <CATALOG_BUILD_SECRET>
 *     FOR TESTING: immediately run notify+execute for one or all due subscriptions,
 *     bypassing the 24h window when { "force": true } is passed.
 *     Body: { "force"?: boolean, "merchantSubscriptionId"?: string }
 *     - If merchantSubscriptionId is specified, only that subscription is processed.
 *     - If force=true, next_debit_at check is skipped (useful in sandbox testing).
 *     This route reuses the same logic as the cron but is callable on demand.
 */

import type { Context } from "hono";
import { buildCatalog } from "../cron/build-catalog.js";
import { sweepSubmissions } from "../cron/sweep-submissions.js";
import { sweepCanonical } from "../cron/sweep-canonical.js";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import {
  notifyRedemption,
  executeRedemption,
  getSubscriptionStatus,
  initiateRefund,
  buildMerchantOrderId,
} from "../lib/phonepe.js";

// ── POST /internal/build-catalog ─────────────────────────────────────────────

export async function handleBuildCatalog(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== env.CATALOG_BUILD_SECRET) {
    return Response.json(
      { error: { code: "unauthorized", message: "Invalid catalog build secret" } },
      { status: 401 },
    );
  }

  let scope: string | null = null;
  try {
    const body = await c.req.json().catch(() => ({})) as Record<string, unknown>;
    if (body?.scope && typeof body.scope === "string") {
      scope = body.scope;
    }
  } catch {
    // no body — build all scopes
  }

  try {
    // Operator-triggered builds always rebuild (force=true). The version gate is a
    // cron-only optimization; forcing here guarantees content changes reflect
    // immediately and prevents stale catalog entries.
    const results = await buildCatalog(env, scope, true);
    return c.json({ ok: true, results });
  } catch (err) {
    console.error("[internal/build-catalog] error:", err);
    return Response.json(
      { error: { code: "server_error", message: "Catalog build failed" } },
      { status: 500 },
    );
  }
}

// ── POST /internal/sweep-submissions ─────────────────────────────────────────
//   Auth: Authorization: Bearer <CATALOG_BUILD_SECRET>
//   Reclaims orphaned user-submission objects from R2 (backstop for the inline
//   delete-on-approve/reject). Called by the hourly CRON and on-demand for testing.

export async function handleSweepSubmissions(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== env.CATALOG_BUILD_SECRET) {
    return Response.json(
      { error: { code: "unauthorized", message: "Invalid secret" } },
      { status: 401 },
    );
  }

  try {
    const result = await sweepSubmissions(env);
    return c.json({ ok: true, result });
  } catch (err) {
    console.error("[internal/sweep-submissions] error:", err);
    return Response.json(
      { error: { code: "server_error", message: "Sweep failed" } },
      { status: 500 },
    );
  }
}

// ── POST /internal/sweep-canonical ───────────────────────────────────────────
//   Auth: Authorization: Bearer <CATALOG_BUILD_SECRET>
//   Reclaims canonical media objects (wallpapers/) that no DB row
//   references — abandoned CMS uploads + lost delete/replace cleanups. Called by
//   the hourly CRON (after the rebuild) and on-demand for testing.

export async function handleSweepCanonical(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== env.CATALOG_BUILD_SECRET) {
    return Response.json(
      { error: { code: "unauthorized", message: "Invalid secret" } },
      { status: 401 },
    );
  }

  try {
    const result = await sweepCanonical(env);
    return c.json({ ok: true, result });
  } catch (err) {
    console.error("[internal/sweep-canonical] error:", err);
    return Response.json(
      { error: { code: "server_error", message: "Sweep failed" } },
      { status: 500 },
    );
  }
}

// ── POST /internal/run-redemptions ───────────────────────────────────────────

export async function handleRunRedemptions(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  // Auth: same CATALOG_BUILD_SECRET
  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== env.CATALOG_BUILD_SECRET) {
    return Response.json(
      { error: { code: "unauthorized", message: "Invalid secret" } },
      { status: 401 },
    );
  }

  let force = false;
  let targetMerchantSubId: string | null = null;
  try {
    const body = await c.req.json().catch(() => ({})) as Record<string, unknown>;
    if (body?.force === true) force = true;
    if (typeof body?.merchantSubscriptionId === "string") {
      targetMerchantSubId = body.merchantSubscriptionId;
    }
  } catch {
    // defaults
  }

  const sql = getDb(env);
  const results: {
    subscriptionId: string;
    notify?: string;
    execute?: string;
    error?: string;
  }[] = [];

  try {
    const now = new Date();

    // Build the query — force bypasses the 24h and next_debit_at checks
    let rows;
    if (targetMerchantSubId) {
      rows = await sql`
        SELECT id, user_id, merchant_subscription_id, redemption_order_id, retry_count, notified_at, next_debit_at
        FROM subscriptions
        WHERE merchant_subscription_id = ${targetMerchantSubId}
          AND status IN ('trialing', 'active')
        LIMIT 1
      `;
    } else if (force) {
      rows = await sql`
        SELECT id, user_id, merchant_subscription_id, redemption_order_id, retry_count, notified_at, next_debit_at
        FROM subscriptions
        WHERE status IN ('trialing', 'active')
        LIMIT 50
      `;
    } else {
      const notifyThreshold = new Date(now.getTime() + 24 * 60 * 60 * 1000);
      rows = await sql`
        SELECT id, user_id, merchant_subscription_id, redemption_order_id, retry_count, notified_at, next_debit_at
        FROM subscriptions
        WHERE status IN ('trialing', 'active')
          AND next_debit_at <= ${notifyThreshold.toISOString()}
        LIMIT 50
      `;
    }

    for (const row of rows) {
      const merchantSubId = row.merchant_subscription_id as string;
      const userId = row.user_id as string;
      const result: (typeof results)[number] = { subscriptionId: merchantSubId };

      try {
        // Step 1: Notify (if not already notified)
        let redemptionOrderId = row.redemption_order_id as string | null;
        if (!redemptionOrderId || force) {
          // Verify ACTIVE before notify
          const subStatus = await getSubscriptionStatus(env, merchantSubId);
          if (subStatus.state !== "ACTIVE") {
            result.error = `Subscription state is ${subStatus.state}, not ACTIVE`;
            results.push(result);
            continue;
          }

          redemptionOrderId = buildMerchantOrderId(userId, "R");
          const notifyRes = await notifyRedemption(env, {
            merchantSubscriptionId: merchantSubId,
            merchantOrderId: redemptionOrderId,
            amountPaise: 19900,
          });
          result.notify = notifyRes.state;

          await sql`
            UPDATE subscriptions
            SET notified_at         = now(),
                redemption_order_id = ${redemptionOrderId},
                updated_at          = now()
            WHERE id = ${row.id as string}
          `;
        } else {
          result.notify = "already_notified";
        }

        // Step 2: Execute
        const execRes = await executeRedemption(env, redemptionOrderId);
        result.execute = execRes.state;

        if (execRes.state === "COMPLETED") {
          const nextPeriodEnd = addOneMonth(new Date());
          await sql`
            UPDATE subscriptions
            SET status              = 'active',
                current_period_end  = ${nextPeriodEnd.toISOString()},
                next_debit_at       = ${nextPeriodEnd.toISOString()},
                notified_at         = NULL,
                redemption_order_id = NULL,
                retry_count         = 0,
                updated_at          = now()
            WHERE id = ${row.id as string}
          `;
        }

      } catch (err) {
        result.error = String(err);
        console.error(`[internal/run-redemptions] Error for sub ${merchantSubId}:`, err);
      }

      results.push(result);
    }

    return c.json({ ok: true, processed: results.length, results });

  } catch (err) {
    console.error("[internal/run-redemptions] error:", err);
    return Response.json(
      { error: { code: "server_error", message: "Run redemptions failed" } },
      { status: 500 },
    );
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /internal/refund ────────────────────────────────────────────────────
//
//   Auth: Authorization: Bearer <CATALOG_BUILD_SECRET>   (operator/support only)
//   Body: { "originalMerchantOrderId": string, "amountPaise"?: number }
//
//   Refunds a ₹199 monthly debit (disputes / goodwill). NOT used for the ₹2 trial
//   validation — PENNY_DROP auto-reverses that, so no refund call is ever needed
//   for the trial. amountPaise defaults to 19900 (full month) if omitted; must be
//   ≤ the original transaction amount.
//
//   The pg.refund.* webhook updates audit logs as the refund settles.

export async function handleRefund(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== env.CATALOG_BUILD_SECRET) {
    return Response.json(
      { error: { code: "unauthorized", message: "Invalid secret" } },
      { status: 401 },
    );
  }

  let originalMerchantOrderId: string | null = null;
  let amountPaise = 19900;
  try {
    const body = await c.req.json().catch(() => ({})) as Record<string, unknown>;
    if (typeof body?.originalMerchantOrderId === "string") {
      originalMerchantOrderId = body.originalMerchantOrderId;
    }
    if (typeof body?.amountPaise === "number" && body.amountPaise > 0) {
      amountPaise = Math.floor(body.amountPaise);
    }
  } catch {
    // fall through to validation
  }

  if (!originalMerchantOrderId) {
    return Response.json(
      { error: { code: "invalid_body", message: "originalMerchantOrderId is required" } },
      { status: 400 },
    );
  }

  try {
    // merchantRefundId must be unique; reuse the order-id builder with a REF tag.
    const merchantRefundId = buildMerchantOrderId(originalMerchantOrderId, "REF").slice(0, 63);
    const result = await initiateRefund(env, originalMerchantOrderId, merchantRefundId, amountPaise);
    return c.json({ ok: true, merchantRefundId, ...result });
  } catch (err) {
    console.error("[internal/refund] error:", err);
    return Response.json(
      { error: { code: "phonepe_error", message: "Refund failed" } },
      { status: 502 },
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function addOneMonth(date: Date): Date {
  const d = new Date(date);
  d.setMonth(d.getMonth() + 1);
  return d;
}
