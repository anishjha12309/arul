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
 *     - If force=true, the next_debit_at check is skipped. DANGER: this worker
 *       runs on PhonePe PRODUCTION credentials, so a forced redemption debits a
 *       real ₹199 from a real customer's account. It is not a dry run — use it
 *       deliberately, against a subscription you own.
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
//   Reclaims canonical media objects under BOTH the wallpapers/ and ringtones/
//   prefixes that no DB row references — full_key, audio_key AND cover_key all
//   count as references. Catches abandoned CMS uploads + lost delete/replace
//   cleanups. Called by the hourly CRON (after the rebuild) and on-demand for
//   testing. This is why the bucket must never be shared with another app.

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

  // Auth: OPS_SECRET — NOT CATALOG_BUILD_SECRET. This route debits real money
  // (force:true charges every due subscriber ₹199 immediately), and
  // CATALOG_BUILD_SECRET is handed to the CMS worker just to trigger rebuilds.
  // One string must never authorize both.
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

  // Auth: OPS_SECRET — moves money, see handleRunRedemptions.
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

  // Never refund more than one month. A fat-fingered amountPaise used to be
  // passed straight to PhonePe; the only ceiling was PhonePe's own
  // "≤ original transaction amount" check.
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

  // The order must actually be OURS. Without this the route would ask PhonePe to
  // refund any merchant order id the caller could name — including one belonging
  // to the OTHER app on the same PhonePe merchant account. Setup orders live in
  // merchant_order_id, redemption orders in redemption_order_id.
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
    // merchantRefundId must be unique; reuse the order-id builder with a REF tag.
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

/** Monthly price in paise (₹199) — the refund ceiling. Mirrors payments.ts. */
const MONTHLY_PRICE_PAISE = 19900;

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Authorize an operator route that MOVES MONEY.
 *
 * Requires OPS_SECRET and nothing else. Fails closed when OPS_SECRET is unset
 * so a missing secret can never silently fall back to a weaker check — an
 * unconfigured Worker refuses to debit rather than accepting any bearer.
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

/** Length-independent constant-time string compare (no early exit on mismatch). */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  // Fold length into the result instead of returning early, so a wrong-length
  // guess is not distinguishable by timing from a wrong-value guess.
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
