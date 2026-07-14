/**
 * Payment routes — PhonePe Standard Checkout v2 (OAuth / O-Bearer)
 *
 *   POST /payments/initiate  — start a PENNY_DROP Autopay mandate (JWT required)
 *   POST /payments/webhook   — PhonePe S2S callback (no JWT; verified by callback auth)
 *   POST /payments/status    — reconcile/return current subscription state (JWT required)
 *
 * Product flow (ONE FREE TRIAL PER USER — trial_end is the consumed-marker):
 *   1. App calls /payments/initiate. Worker checks subscriptions.trial_end:
 *        NULL     → trial-eligible → PENNY_DROP setup (₹2 auto-reversed)
 *        NOT NULL → trial consumed → TRANSACTION setup (real ₹199 first debit)
 *      → upserts subscriptions row (status='pending') → returns { token, … }
 *   2. Flutter SDK opens the PhonePe mandate screen
 *   3. PhonePe sends webhook (checkout.order.completed):
 *        first setup  → status='trialing', trial_end/current_period_end/next_debit_at = now+1d
 *        repeat setup → status='active' (₹199 already charged), period/next debit = +1 month
 *   4. Autopay cron (hourly): notify (24h before) + execute at next_debit_at
 *      → on success: status='active', current_period_end = +1 month, next cycle
 *
 * Idempotency:
 *   - Webhook events deduped by KV key "txn:<orderId>" (30-day TTL)
 *   - DB writes use ON CONFLICT DO UPDATE
 *
 * Security:
 *   - /payments/initiate + /payments/status: require valid access JWT
 *   - /payments/webhook: verify PhonePe callback Authorization header
 *     Authorization = SHA256(username + ":" + password) hex
 *
 * Response shapes (Flutter app depends on these):
 *
 *   POST /payments/initiate → 200:
 *   {
 *     "merchantSubscriptionId": "DKS_S_...",
 *     "merchantOrderId": "DKS_O_...",
 *     "orderId": "<PhonePe-generated>",
 *     "state": "PENDING",
 *     "redirectUrl": "upi://...",         // intent URL for the Flutter SDK
 *     "merchantId": "<PHONEPE_MERCHANT_ID>",
 *     "environment": "SANDBOX" | "PRODUCTION"
 *   }
 *
 *   POST /payments/status → 200:
 *   {
 *     "subscription": {                   // matches SubscriptionModel.fromJson
 *       "id": "<uuid>",
 *       "user_id": "<uuid>",
 *       "status": "pending"|"trialing"|"active"|"expired"|"cancelled",
 *       "plan": "monthly",
 *       "merchant_subscription_id": "...",
 *       "merchant_order_id": "...",
 *       "phonepe_order_id": "...",
 *       "current_period_end": "<ISO8601>" | null,
 *       "next_debit_at": "<ISO8601>" | null,
 *       "trial_end": "<ISO8601>" | null,
 *       "updated_at": "<ISO8601>"
 *     },
 *     "phonepe": {                        // live PhonePe status (may be null on error)
 *       "state": "PENDING"|"COMPLETED"|"...",
 *       "orderId": "..."
 *     } | null
 *   }
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  setupSubscription,
  revokeMandateTolerant,
  verifyCallbackAuth,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantSubscriptionId,
  buildMerchantOrderId,
  type PhonePeWebhookPayload,
} from "../lib/phonepe.js";

const KV_TXN_TTL = 30 * 24 * 60 * 60; // 30 days — covers PhonePe's retry window

/** Monthly price in paise (₹199) — must match maxAmount in phonepe.ts. */
const MONTHLY_PRICE_PAISE = 19900;

/**
 * Free-trial length. The ₹2 PENNY_DROP only authorizes the mandate (PhonePe
 * auto-reverses it); the trial itself is ours, granted here and nowhere else.
 *
 * Both the webhook and the /payments/status reconcile grant the trial, and they
 * MUST agree — a drift between them would give some users a different trial than
 * others depending on which path confirmed their mandate first. Hence one
 * constant, not two literals.
 *
 * Also the debit clock: next_debit_at = now + this, so the paywall copy must say
 * the same number or we charge users earlier than we promised.
 */
const TRIAL_DAYS = 1;
const TRIAL_MS = TRIAL_DAYS * 24 * 60 * 60 * 1000;

// ── POST /payments/initiate ──────────────────────────────────────────────────

export async function handleInitiate(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: { plan?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { plan } = body;
  // v1: monthly only. Yearly is accepted for schema compatibility but maps to monthly for now.
  if (plan !== "monthly" && plan !== "yearly") {
    return errorResponse(400, "invalid_plan", "plan must be 'monthly' or 'yearly'");
  }

  const sql = getDb(env);
  try {
    // ── One free trial per user ────────────────────────────────────────────
    // trial_end is written exactly once — the first time a mandate setup
    // completes (webhook/reconcile COALESCE it, never overwrite). So a non-null
    // trial_end means this user already consumed their trial: authorize the new
    // mandate with a REAL ₹199 first debit (TRANSACTION) instead of the ₹2
    // PENNY_DROP, and skip the trial on completion.
    const prior = await sql<{ trial_end: string | null }[]>`
      SELECT trial_end FROM subscriptions WHERE user_id = ${sub} LIMIT 1
    `;
    const trialEligible = prior.length === 0 || prior[0].trial_end === null;

    // Build unique IDs
    const merchantSubscriptionId = buildMerchantSubscriptionId(sub);
    const merchantOrderId = buildMerchantOrderId(sub, "S");

    // Redirect URL PhonePe sends the user back to after mandate authorization.
    // Derive the origin from the incoming request so it always matches the host
    // the app actually called (api.hsrutility.com today) — never a stale hardcode.
    const origin = new URL(c.req.url).origin;
    const redirectUrl = `${origin}/payments/callback?sub=${encodeURIComponent(sub)}`;

    // Call PhonePe Standard Checkout v2 — PENNY_DROP setup
    let ppResult;
    try {
      ppResult = await setupSubscription(env, {
        userId: sub,
        merchantSubscriptionId,
        merchantOrderId,
        redirectUrl,
        upfrontAmountPaise: trialEligible ? undefined : MONTHLY_PRICE_PAISE,
      });
    } catch (ppErr) {
      console.error("[payments/initiate] PhonePe error:", ppErr);
      return errorResponse(502, "phonepe_error", "PhonePe gateway error");
    }

    // Persist pending subscription intent
    // ON CONFLICT on user_id: a user can only have one active subscription row.
    // We overwrite pending state but never overwrite an active/trialing one.
    await sql`
      INSERT INTO subscriptions (
        user_id, status, plan,
        merchant_subscription_id, merchant_order_id, phonepe_order_id
      )
      VALUES (
        ${sub}, 'pending', ${plan},
        ${merchantSubscriptionId}, ${merchantOrderId}, ${ppResult.orderId}
      )
      ON CONFLICT (user_id)
      DO UPDATE SET
        status                   = CASE
                                     WHEN subscriptions.status IN ('active', 'trialing')
                                     THEN subscriptions.status
                                     ELSE 'pending'
                                   END,
        plan                     = EXCLUDED.plan,
        merchant_subscription_id = EXCLUDED.merchant_subscription_id,
        merchant_order_id        = EXCLUDED.merchant_order_id,
        phonepe_order_id         = EXCLUDED.phonepe_order_id,
        updated_at               = now()
    `;

    // The Flutter SDK's startTransaction needs the SDK order token, returned as
    // the top-level `token` by the Create SDK Order endpoint — see phonepe.ts.
    return c.json({
      merchantSubscriptionId,
      merchantOrderId,
      orderId: ppResult.orderId,
      state: ppResult.state,
      redirectUrl: ppResult.redirectUrl,
      token: ppResult.token,
      expireAt: ppResult.expireAt,
      merchantId: env.PHONEPE_MERCHANT_ID,
      environment: env.PHONEPE_ENV,
      // Additive — old app versions ignore these. trialEligible=false means the
      // user is being charged ₹199 upfront (amountPaise) at mandate setup.
      trialEligible,
      amountPaise: trialEligible ? 200 : MONTHLY_PRICE_PAISE,
    });
  } catch (err) {
    console.error("[payments/initiate] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /payments/webhook ───────────────────────────────────────────────────

export async function handleWebhook(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  // 1. Verify PhonePe callback Authorization header
  //    Authorization = SHA256(username + ":" + password) hex
  const authHeader = c.req.header("Authorization") ?? "";
  const webhookUsername = env.PHONEPE_WEBHOOK_USERNAME ?? "";
  const webhookPassword = env.PHONEPE_WEBHOOK_PASSWORD ?? "";

  if (!webhookUsername || !webhookPassword) {
    // Missing secrets = misconfiguration; fail closed
    console.error("[payments/webhook] PHONEPE_WEBHOOK_USERNAME/PASSWORD not set");
    return new Response("ok", { status: 200 }); // ack to stop retries; alert on logs
  }

  const authValid = await verifyCallbackAuth(authHeader, webhookUsername, webhookPassword);
  if (!authValid) {
    return errorResponse(401, "invalid_signature", "Webhook authorization failed");
  }

  // 2. Parse payload
  let payload: PhonePeWebhookPayload;
  try {
    const rawBody = await c.req.text();
    payload = JSON.parse(rawBody) as PhonePeWebhookPayload;
  } catch {
    return errorResponse(400, "invalid_body", "Invalid JSON payload");
  }

  // PhonePe's docs are inconsistent about the field name and casing: some show
  // `event: "checkout.order.completed"` (dotted, lower), others
  // `type: "CHECKOUT_ORDER_COMPLETED"` (UPPER_SNAKE). Normalize BOTH to the
  // dotted-lower form so our switch matches regardless: UPPER_SNAKE → lower, then
  // "_" → "." (e.g. SUBSCRIPTION_REVOKED → subscription.revoked).
  const rawEvent = payload.event ?? payload.type ?? "";
  const event = rawEvent.toLowerCase().replace(/_/g, ".");
  const pp = payload.payload ?? {};

  // 3. Idempotency — dedupe on PhonePe orderId
  const dedupeKey = pp.orderId ?? pp.merchantOrderId ?? "";
  if (!dedupeKey) {
    console.error("[payments/webhook] Missing orderId/merchantOrderId, event:", event);
    return new Response("ok", { status: 200 });
  }

  const kvKey = `txn:${dedupeKey}`;
  const alreadyProcessed = await env.KV.get(kvKey);
  if (alreadyProcessed) {
    console.log(`[payments/webhook] Already processed ${dedupeKey}, event: ${event}`);
    return new Response("ok", { status: 200 });
  }

  const merchantSubId = pp.merchantSubscriptionId;
  if (!merchantSubId) {
    console.error("[payments/webhook] Missing merchantSubscriptionId, event:", event);
    await env.KV.put(kvKey, "1", { expirationTtl: KV_TXN_TTL });
    return new Response("ok", { status: 200 });
  }

  const sql = getDb(env);
  try {
    // 4. Route by event type
    if (event === "checkout.order.completed") {
      // Mandate setup succeeded. ONE FREE TRIAL PER USER:
      //   trial_end IS NULL (first ever setup)  → 'trialing', 1-day free trial
      //   trial_end NOT NULL (trial consumed)   → 'active' — initiate authorized
      //     this mandate with a real ₹199 first debit (TRANSACTION), so the user
      //     already paid for the month; period ends +1 month.
      // The CASE expressions read the row's OLD trial_end (Postgres SET
      // semantics), so the decision + write is a single atomic statement.
      // COALESCE keeps the original trial_end forever as the consumed-marker.
      const trialEnd = new Date(Date.now() + TRIAL_MS);
      const paidEnd = addOneMonth(new Date());
      const phonepeSubId = pp.subscriptionId ?? null;

      const updated = await sql<{ user_id: string; status: string }[]>`
        UPDATE subscriptions
        SET status                   = CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END,
            phonepe_subscription_id  = ${phonepeSubId},
            trial_end                = COALESCE(trial_end, ${trialEnd.toISOString()}),
            current_period_end       = CASE WHEN trial_end IS NULL
                                            THEN ${trialEnd.toISOString()}::timestamptz
                                            ELSE ${paidEnd.toISOString()}::timestamptz END,
            next_debit_at            = CASE WHEN trial_end IS NULL
                                            THEN ${trialEnd.toISOString()}::timestamptz
                                            ELSE ${paidEnd.toISOString()}::timestamptz END,
            notified_at              = NULL,
            retry_count              = 0,
            updated_at               = now()
        WHERE merchant_subscription_id = ${merchantSubId}
        RETURNING user_id, status
      `;

      const row = updated[0];
      console.log(
        `[payments/webhook] Setup completed for sub ${merchantSubId} → ` +
        `${row?.status ?? "no-row"}, amount=${pp.amount ?? "?"}`,
      );

      if (row?.status === "active") {
        // Repeat subscriber paid ₹199 at setup — that IS a paid debit, so the
        // referral reward (idempotent) applies here just like a redemption.
        await grantReferralReward(sql, row.user_id);
        // Audit: a repeat subscriber's setup order should carry the real charge.
        // amount=200 here would mean a stale PENNY_DROP order (created before
        // this guard deployed) completed for a trial-consumed user.
        if (typeof pp.amount === "number" && pp.amount < MONTHLY_PRICE_PAISE) {
          console.warn(
            `[payments/webhook] Trial-consumed user activated via setup order of only ${pp.amount} paise (sub ${merchantSubId})`,
          );
        }
      }

    } else if (event === "checkout.order.failed") {
      // Mandate setup failed
      await sql`
        UPDATE subscriptions
        SET status     = 'expired',
            updated_at = now()
        WHERE merchant_subscription_id = ${merchantSubId}
          AND status = 'pending'
      `;

    } else if (
      event === "subscription.redemption.order.completed" ||
      event === "subscription.redemption.transaction.completed"
    ) {
      // Debit succeeded → move to active, extend period by 1 month
      const nextEnd = addOneMonth(new Date());
      const phonepeSubId = pp.subscriptionId ?? null;

      const activated = await sql<{ user_id: string }[]>`
        UPDATE subscriptions
        SET status                  = 'active',
            phonepe_subscription_id = COALESCE(${phonepeSubId}, phonepe_subscription_id),
            current_period_end      = ${nextEnd.toISOString()},
            next_debit_at           = ${nextEnd.toISOString()},
            notified_at             = NULL,
            retry_count             = 0,
            updated_at              = now()
        WHERE merchant_subscription_id = ${merchantSubId}
        RETURNING user_id
      `;

      console.log(`[payments/webhook] Active for sub ${merchantSubId}, period_end=${nextEnd.toISOString()}`);

      // Referral reward: this user just made a paid debit. Idempotent — only the
      // FIRST ever grants (renewals/retries no-op via the status<>'rewarded' guard).
      if (activated.length > 0) {
        await grantReferralReward(sql, activated[0].user_id);
      }

    } else if (
      event === "subscription.redemption.order.failed" ||
      event === "subscription.redemption.transaction.failed"
    ) {
      // Debit failed — STANDARD retry strategy means PhonePe auto-retries up to 48h.
      // Increment retry_count. Terminal failure is handled by the cron after expiry window.
      await sql`
        UPDATE subscriptions
        SET retry_count = retry_count + 1,
            updated_at  = now()
        WHERE merchant_subscription_id = ${merchantSubId}
      `;
      console.log(`[payments/webhook] Redemption failed for sub ${merchantSubId}, event: ${event}`);

    } else if (
      event === "subscription.revoked" ||
      event === "subscription.cancelled"
    ) {
      // Mandate revoked (by user from their PSP app or by our cancel call).
      // Stop future debits but DON'T strip entitlement — the user keeps premium
      // until current_period_end (they already paid for the current cycle).
      await sql`
        UPDATE subscriptions
        SET status        = 'cancelled',
            next_debit_at  = NULL,
            notified_at    = NULL,
            updated_at     = now()
        WHERE merchant_subscription_id = ${merchantSubId}
      `;

    } else if (event === "subscription.paused") {
      await sql`
        UPDATE subscriptions
        SET status     = 'paused',
            updated_at = now()
        WHERE merchant_subscription_id = ${merchantSubId}
      `;

    } else if (event === "subscription.unpaused") {
      // Resume — back to active (or trialing if still inside trial window).
      await sql`
        UPDATE subscriptions
        SET status     = CASE
                           WHEN trial_end IS NOT NULL AND trial_end > now()
                           THEN 'trialing' ELSE 'active'
                         END,
            updated_at = now()
        WHERE merchant_subscription_id = ${merchantSubId}
      `;

    } else if (
      event === "pg.refund.accepted" ||
      event === "pg.refund.completed" ||
      event === "pg.refund.failed"
    ) {
      // Refunds are operator/support-initiated (₹199 disputes/goodwill) — the ₹2
      // trial validation auto-reverses and does NOT emit these. We don't mutate
      // subscription state here (a refund doesn't end the mandate); log for audit.
      console.log(
        `[payments/webhook] Refund event ${event} for sub ${merchantSubId}, ` +
        `order=${pp.merchantOrderId ?? pp.orderId}, state=${pp.state}`,
      );

    } else {
      // Unhandled event — log and ack
      console.log(`[payments/webhook] Unhandled event: ${event}, sub: ${merchantSubId}`);
    }

    // 5. Mark idempotent
    await env.KV.put(kvKey, "1", { expirationTtl: KV_TXN_TTL });
    return new Response("ok", { status: 200 });

  } catch (err) {
    console.error("[payments/webhook] DB error:", err);
    // Return 200 to prevent PhonePe retry storm; alert via logs
    return new Response("ok", { status: 200 });
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /payments/status ────────────────────────────────────────────────────

export async function handleStatus(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    // Fetch our subscription row
    const rows = await sql`
      SELECT
        id, user_id, status, plan,
        merchant_subscription_id, merchant_order_id, phonepe_order_id,
        phonepe_subscription_id, current_period_end, trial_end,
        next_debit_at, notified_at, retry_count, updated_at
      FROM subscriptions
      WHERE user_id = ${sub}
      LIMIT 1
    `;

    if (rows.length === 0) {
      return c.json({ subscription: null, phonepe: null });
    }

    const row = rows[0];

    // Optionally reconcile with live PhonePe status
    let phonePeStatus: { state: string; orderId?: string } | null = null;
    const merchantOrderId = row.merchant_order_id as string | null;
    const merchantSubId = row.merchant_subscription_id as string | null;

    if (merchantOrderId) {
      try {
        const orderStatus = await getOrderStatus(env, merchantOrderId);
        phonePeStatus = { state: orderStatus.state, orderId: orderStatus.orderId };

        // Reconcile: if PhonePe says COMPLETED but we're still pending, update.
        // Mirrors the webhook's one-trial-per-user branch: trial_end IS NULL →
        // first trial; already set → repeat subscriber who paid ₹199 at setup
        // (TRANSACTION mandate) → straight to 'active' for a month.
        if (
          orderStatus.state === "COMPLETED" &&
          (row.status as string) === "pending"
        ) {
          const trialEnd = new Date(Date.now() + TRIAL_MS);
          const paidEnd = addOneMonth(new Date());
          const phonepeSubId = orderStatus.paymentFlow?.subscriptionId ?? null;
          const updated = await sql<{ user_id: string; status: string }[]>`
            UPDATE subscriptions
            SET status                   = CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END,
                phonepe_subscription_id  = ${phonepeSubId},
                trial_end                = COALESCE(trial_end, ${trialEnd.toISOString()}),
                current_period_end       = CASE WHEN trial_end IS NULL
                                                THEN ${trialEnd.toISOString()}::timestamptz
                                                ELSE ${paidEnd.toISOString()}::timestamptz END,
                next_debit_at            = CASE WHEN trial_end IS NULL
                                                THEN ${trialEnd.toISOString()}::timestamptz
                                                ELSE ${paidEnd.toISOString()}::timestamptz END,
                notified_at              = NULL,
                retry_count              = 0,
                updated_at               = now()
            WHERE user_id = ${sub}
              AND status  = 'pending'
            RETURNING user_id, status
          `;
          if (updated[0]) {
            row.status = updated[0].status;
            if (updated[0].status === "active") {
              // Same paid-debit semantics as the webhook path (idempotent).
              await grantReferralReward(sql, updated[0].user_id);
            }
          }
        }
      } catch (ppErr) {
        // PhonePe call failed — non-fatal, return DB state only
        console.warn("[payments/status] PhonePe order status failed:", ppErr);
      }
    }

    // Reconcile revoke/cancel for a live mandate. A user who revokes the mandate
    // directly in their PhonePe/UPI app usually triggers NO merchant webhook, so
    // our row stays 'trialing'/'active'. Poll the live mandate state and flip to
    // 'cancelled' if PhonePe says it's gone — we KEEP current_period_end so the
    // user retains access for the cycle they already paid for. Scoped to
    // trialing/active so the pending-setup poll above isn't double-charged a call.
    if (
      merchantSubId &&
      ((row.status as string) === "trialing" || (row.status as string) === "active")
    ) {
      try {
        const subStatus = await getSubscriptionStatus(env, merchantSubId);
        phonePeStatus = phonePeStatus ?? { state: subStatus.state };
        if (subStatus.state === "CANCELLED" || subStatus.state === "REVOKED") {
          await sql`
            UPDATE subscriptions
            SET status        = 'cancelled',
                next_debit_at = NULL,
                notified_at   = NULL,
                updated_at    = now()
            WHERE user_id = ${sub}
              AND status IN ('trialing', 'active')
          `;
          row.status = "cancelled";
        }
      } catch (ppErr) {
        console.warn("[payments/status] PhonePe subscription status failed:", ppErr);
      }
    }

    return c.json({
      // Top-level `status` is what the app's purchase poll reads (premium_purchase_provider).
      // The nested `subscription` object matches SubscriptionModel (snake_case) for /me parity.
      status: row.status,
      subscription: {
        id: row.id,
        user_id: row.user_id,
        status: row.status,
        plan: row.plan,
        merchant_subscription_id: row.merchant_subscription_id,
        merchant_order_id: row.merchant_order_id,
        phonepe_order_id: row.phonepe_order_id,
        current_period_end: row.current_period_end,
        trial_end: row.trial_end,
        next_debit_at: row.next_debit_at,
        updated_at: row.updated_at,
      },
      phonepe: phonePeStatus,
    });

  } catch (err) {
    console.error("[payments/status] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /payments/cancel ──────────────────────────────────────────────────────
//
// User-initiated cancellation ("Manage Subscription"). Revokes the PhonePe mandate
// so no further debits occur. Entitlement is NOT stripped here — the user keeps
// premium until current_period_end (they paid for the current cycle). The
// subscription.cancelled webhook finalizes status='cancelled'; we also set it
// locally so the UI updates immediately without waiting for the callback.

export async function handleCancel(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT merchant_subscription_id, status
      FROM subscriptions
      WHERE user_id = ${sub}
      LIMIT 1
    `;

    if (rows.length === 0) {
      return errorResponse(404, "not_found", "No subscription to cancel");
    }

    const merchantSubId = rows[0].merchant_subscription_id as string | null;
    const status = rows[0].status as string;

    if (status === "cancelled" || status === "expired") {
      // Idempotent — already terminal.
      return c.json({ status, cancelled: true });
    }

    if (!merchantSubId) {
      return errorResponse(409, "no_mandate", "Subscription has no PhonePe mandate to revoke");
    }

    // Tolerates the already-inactive case (user revoked from their UPI app —
    // that IS the desired end state); only a mandate PhonePe still reports
    // live is a genuine transient failure worth retrying.
    const revoked = await revokeMandateTolerant(env, merchantSubId);
    if (!revoked) {
      return errorResponse(
        502,
        "phonepe_error",
        "Could not cancel with PhonePe. Please try again.",
      );
    }

    // Stop future debits locally; keep entitlement until current_period_end.
    await sql`
      UPDATE subscriptions
      SET status        = 'cancelled',
          next_debit_at = NULL,
          notified_at   = NULL,
          updated_at    = now()
      WHERE user_id = ${sub}
    `;

    return c.json({ status: "cancelled", cancelled: true });
  } catch (err) {
    console.error("[payments/cancel] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── GET /payments/callback ───────────────────────────────────────────────────────
//
// PhonePe redirects the in-app browser/intent here after the user completes the
// mandate (the redirectUrl we pass to setupSubscription points at this route).
// Authoritative state comes from the S2S webhook + the app's /payments/status
// poll — this page only needs to exist so the redirect doesn't 404, and to nudge
// the user back to the app.

export function handleCallback(c: Context<{ Bindings: Env }>): Response {
  const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<title>Arul</title></head><body style="font-family:system-ui;text-align:center;padding:48px 24px;color:#2B1116">` +
    `<h2 style="color:#1FA75A">Payment received</h2>` +
    `<p>You can return to the Arul app. Your subscription will activate in a moment.</p>` +
    `</body></html>`;
  return c.html(html);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function addOneMonth(date: Date): Date {
  const d = new Date(date);
  d.setMonth(d.getMonth() + 1);
  return d;
}

async function requireAuth(c: Context<{ Bindings: Env }>): Promise<string | null> {
  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const claims = await verifyAccessToken(token, c.env.JWT_SECRET);
    return claims.sub;
  } catch {
    return null;
  }
}

function errorResponse(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}
