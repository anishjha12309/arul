/**
 * Internal routes — operator and cron only. TWO different secrets guard them; check each handler.
 *
 * CATALOG_BUILD_SECRET guards the SAFE routes: build-catalog, sweep-submissions, sweep-canonical
 * OPS_SECRET guards the routes that MOVE MONEY: run-redemptions and refund -> never widen either
 * /internal/run-redemptions with { force: true } skips the next_debit_at and 24h checks
 * This Worker runs on PhonePe PRODUCTION credentials -> a forced redemption debits a REAL ₹199 -> not a dry run
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
    // An operator-triggered build ALWAYS rebuilds -> the version gate is a cron-only optimization
    // Applying it here would skip a rebuild a publish or delete actually needed -> the catalog would stay stale
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
//   Auth: Bearer CATALOG_BUILD_SECRET -> a content route, so the CMS's secret is the right one
//   The backstop for the inline delete-on-approve/reject -> the daily cron runs it, this is the on-demand door

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
//   Auth: Bearer CATALOG_BUILD_SECRET -> a content route, so the CMS's secret is the right one
//   Reclaims canonical objects no DB row references -> full_key, audio_key AND cover_key all count as references
//   It catches abandoned CMS uploads and lost delete/replace cleanups -> neither is ever retried inline
//   The hourly cron runs it only when a scope changed; the daily cron runs it unconditionally
//   It deletes anything unreferenced under its prefixes -> NEVER share this bucket with another app

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

  // Auth: OPS_SECRET, NOT CATALOG_BUILD_SECRET -> force:true charges every due subscriber ₹199 immediately
  // CATALOG_BUILD_SECRET is handed to the CMS just to trigger rebuilds -> one string must never authorize both
  if (!authorizeOps(c, env)) {
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

    // force bypasses BOTH the 24h notify window and the next_debit_at check -> it debits rows that are not due
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
          // PhonePe requires the mandate be verified ACTIVE before a notify
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
//   Auth: Bearer OPS_SECRET -> operator and support only -> this route moves real money
//   Refunds a ₹199 monthly debit for a dispute or goodwill -> amountPaise defaults to the full month
//   NEVER needed for the ₹2 trial validation -> PENNY_DROP auto-reverses that on its own
//   The pg.refund.* webhook updates the audit log as the refund settles -> this call only starts it

export async function handleRefund(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  // Auth: OPS_SECRET -> this moves money -> see handleRunRedemptions
  if (!authorizeOps(c, env)) {
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

  // Never refund more than one month -> a fat-fingered amountPaise reached PhonePe unchecked
  // The only ceiling was PhonePe's own "<= original transaction amount" -> that is not our business rule
  if (amountPaise > MONTHLY_PRICE_PAISE) {
    return Response.json(
      {
        error: {
          code: "amount_too_large",
          message: `amountPaise must be <= ${MONTHLY_PRICE_PAISE} (one month)`,
        },
      },
      { status: 400 },
    );
  }

  // The order must actually be OURS -> without this the route refunds any merchant order id a caller can name
  // That includes one belonging to the OTHER app on the same PhonePe merchant account
  // Setup orders live in merchant_order_id, redemption orders in redemption_order_id -> check both columns
  const sql = getDb(env);
  let ownerUserId: string;
  try {
    const rows = (await sql`
      SELECT user_id FROM subscriptions
      WHERE merchant_order_id = ${originalMerchantOrderId}
         OR redemption_order_id = ${originalMerchantOrderId}
      LIMIT 1
    `) as unknown as { user_id: string }[];
    if (rows.length === 0) {
      return Response.json(
        {
          error: {
            code: "unknown_order",
            message: "No subscription in this app owns that merchantOrderId",
          },
        },
        { status: 404 },
      );
    }
    ownerUserId = rows[0].user_id;
  } catch (err) {
    console.error("[internal/refund] order lookup failed:", err);
    return Response.json(
      { error: { code: "server_error", message: "Could not verify the order" } },
      { status: 500 },
    );
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  try {
    // merchantRefundId must be UNIQUE -> reuse the order-id builder with a REF tag rather than inventing a scheme
    const merchantRefundId = buildMerchantOrderId(originalMerchantOrderId, "REF").slice(0, 63);
    const result = await initiateRefund(env, originalMerchantOrderId, merchantRefundId, amountPaise);
    console.log(
      `[internal/refund] ${amountPaise} paise on ${originalMerchantOrderId} ` +
      `(user ${ownerUserId}) -> ${result.state} refundId=${result.refundId}`,
    );
    return c.json({ ok: true, merchantRefundId, ...result });
  } catch (err) {
    console.error("[internal/refund] error:", err);
    return Response.json(
      { error: { code: "phonepe_error", message: "Refund failed" } },
      { status: 502 },
    );
  }
}

/** Monthly price in paise, and the refund ceiling -> mirrored in payments.ts -> change both together. */
const MONTHLY_PRICE_PAISE = 19900;

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Authorize an operator route that MOVES MONEY. OPS_SECRET and nothing else.
 * FAILS CLOSED when OPS_SECRET is unset -> an unconfigured Worker refuses to debit rather than accept any bearer
 */
function authorizeOps(c: Context<{ Bindings: Env }>, env: Env): boolean {
  const expected = env.OPS_SECRET ?? "";
  if (!expected) {
    console.error("[internal] OPS_SECRET is not set — refusing money-moving route");
    return false;
  }
  const token = (c.req.header("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return false;
  return timingSafeEqual(token, expected);
}

/** Length-independent constant-time compare -> an early exit on mismatch leaks the secret one byte at a time. */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  // Fold length INTO the result rather than returning early -> a wrong-length guess must time like a wrong-value one
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

function addOneMonth(date: Date): Date {
  const d = new Date(date);
  d.setMonth(d.getMonth() + 1);
  return d;
}
