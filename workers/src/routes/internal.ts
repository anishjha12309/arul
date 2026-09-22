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
import { pushEnabled, runPushDispatch, runPushTest } from "../cron/push-dispatch.js";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import type { PushCampaign } from "../lib/fcm.js";
import { audienceQuery, parseAudience } from "../lib/push-audience.js";
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

  // `?dry_run=1` -> decide everything, delete nothing, return `wouldDelete` -> read it BEFORE the real call
  // R2 has no versioning -> this is the only preview an operator gets of the one action with no undo
  const dryRun = c.req.query("dry_run") === "1";
  try {
    const result = await sweepCanonical(env, { dryRun });
    return c.json({ ok: true, dryRun, result });
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
                first_debit_at      = COALESCE(first_debit_at, now()),
                debit_count         = debit_count + 1,
                paid_paise          = paid_paise + 19900,
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

// ── Campaign push routes (the CMS's Notifications page) ──────────────────────
//   Auth: Bearer PUSH_SECRET -> a THIRD secret, deliberately.
//   CATALOG_BUILD_SECRET already lives in the CMS to trigger rebuilds; one string must never
//   authorize "rebuild the catalog" AND "message every user". OPS_SECRET moves money and stays
//   nowhere near the CMS. Fails closed when unset, exactly like authorizeOps.

/**
 * POST /internal/push/count { audience } -> { devices }
 *
 * The composer's live counts. The SQL lives in lib/push-audience.ts and NOWHERE else -> a copy in the
 * CMS would be a number that disagrees with what the send actually reaches.
 */
export async function handlePushCount(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  if (!authorizePush(c, env)) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }

  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const audience = parseAudience(body?.["audience"]);
  if (!audience) {
    return Response.json(
      { error: { code: "invalid_body", message: "audience is required and must be a known kind" } },
      { status: 400 },
    );
  }

  const sql = getDb(env);
  try {
    const rows = (await sql`
      SELECT count(*)::int AS n FROM (${audienceQuery(sql, audience)}) q
    `) as unknown as { n: number }[];
    return c.json({ devices: rows[0]?.n ?? 0 });
  } catch (err) {
    console.error("[internal/push/count] error:", err);
    return Response.json(
      { error: { code: "server_error", message: "Could not count phones" } },
      { status: 500 },
    );
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

/**
 * POST /internal/push/dispatch { campaign_id } -> 202
 *
 * "Send now" only. A scheduled campaign needs no call at all — the minute cron picks it up on its own,
 * and this exists so the operator sees movement within seconds rather than at the next tick.
 * The campaign id is accepted for the log line; the dispatcher claims every due campaign regardless,
 * which is what keeps one code path for both doors.
 */
export async function handlePushDispatch(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  if (!authorizePush(c, env)) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }
  if (!pushEnabled(env)) {
    console.log("[internal/push/dispatch] PUSH_ENABLED is not \"true\" — nothing claimed");
    return c.json({ ok: true, dispatched: false, reason: "disabled" }, 202);
  }

  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const campaignId = typeof body?.["campaign_id"] === "string" ? body["campaign_id"] : "(all due)";
  console.log(`[internal/push/dispatch] starting a dispatch pass for ${campaignId}`);

  c.executionCtx.waitUntil(
    runPushDispatch(env)
      .then((r: unknown) => console.log("[internal/push/dispatch] pass complete:", JSON.stringify(r)))
      .catch((err: unknown) => console.error("[internal/push/dispatch] pass failed:", err)),
  );
  return c.json({ ok: true, dispatched: true }, 202);
}

/**
 * POST /internal/push/test { campaign_id } -> { sent, failed, errors }
 *
 * "Send to my phone". Reaches ONLY `users.is_internal` devices and touches neither the campaign's
 * counters nor its status, so a draft can be tested as many times as the editor likes.
 * IGNORES PUSH_ENABLED on purpose: proving the chain on the owner's phones while production is dark is
 * the entire reason the switch exists.
 */
export async function handlePushTest(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  if (!authorizePush(c, env)) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }

  const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
  const campaignId = body?.["campaign_id"];
  if (typeof campaignId !== "string" || campaignId.length === 0) {
    return Response.json(
      { error: { code: "invalid_body", message: "campaign_id is required" } },
      { status: 400 },
    );
  }

  const sql = getDb(env);
  let campaign: PushCampaign | null = null;
  try {
    const rows = (await sql`
      SELECT id, texts, dest, dest_id, image_url, color, expires_hours
      FROM push_campaigns WHERE id = ${campaignId} LIMIT 1
    `) as unknown as PushCampaign[];
    campaign = rows[0] ?? null;
  } catch (err) {
    console.error("[internal/push/test] lookup failed:", err);
    return Response.json(
      { error: { code: "server_error", message: "Could not read that notification" } },
      { status: 500 },
    );
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
  if (!campaign) {
    return Response.json(
      { error: { code: "not_found", message: "No such notification" } },
      { status: 404 },
    );
  }

  try {
    const result = await runPushTest(env, campaign);
    return c.json({ ok: true, ...result });
  } catch (err) {
    console.error("[internal/push/test] send failed:", err);
    return Response.json(
      { error: { code: "fcm_error", message: String(err) } },
      { status: 502 },
    );
  }
}

/**
 * Authorize a push route. PUSH_SECRET and nothing else.
 * FAILS CLOSED when unset -> an unconfigured Worker refuses to message anyone rather than accept any bearer
 */
function authorizePush(c: Context<{ Bindings: Env }>, env: Env): boolean {
  const expected = env.PUSH_SECRET ?? "";
  if (!expected) {
    console.error("[internal] PUSH_SECRET is not set — refusing push route");
    return false;
  }
  const token = (c.req.header("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return false;
  return timingSafeEqual(token, expected);
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
