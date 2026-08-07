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
import { getDb, toDate } from "../lib/db.js";
import { grantReferralReward } from "../lib/referral.js";
import { reportServerPurchase, normalizeAppInstanceId } from "../lib/ga4.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
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

/**
 * How long a claimed-but-unfinished mandate setup blocks a second attempt.
 *
 * Long enough to cover a slow PhonePe setup call plus the user reaching the
 * mandate sheet, short enough that a genuinely abandoned setup (app killed at
 * the PhonePe screen) does not lock the user out of retrying for long. A
 * blocked caller gets 409 and the app's normal "already subscribed" path.
 */
const SETUP_CLAIM_WINDOW_MS = 90_000;

/** The columns handleInitiate reads under the per-user lock. */
interface PriorSubscription {
  trial_end: unknown;
  status: string;
  merchant_subscription_id: string | null;
  current_period_end: unknown;
  updated_at: unknown;
}

/**
 * Why a claim was refused. The two reasons MUST stay distinguishable all the way
 * out to the client: "you already pay us" is a success the app should celebrate
 * (it flips to Manage Subscription), while "your own setup is still running" is
 * a transient retry — and answering the second with the first told a user who
 * double-tapped that their purchase had succeeded when NO mandate existed.
 */
type ClaimConflict = "active_subscription" | "setup_in_flight";

/** What the claim transaction hands back to the rest of handleInitiate. */
type ClaimResult =
  | { conflict: ClaimConflict; supersededMandateId?: undefined; trialEligible?: undefined }
  | { conflict: false; supersededMandateId: string | null; trialEligible: boolean };

// ── POST /payments/initiate ──────────────────────────────────────────────────

export async function handleInitiate(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // Every call here creates a real PhonePe mandate-setup order. Keyed by user
  // so one abusive account can't burn the PhonePe API quota for everyone.
  if (!(await allowRequest(env.RL_PAYMENTS, `initiate:${sub}`))) {
    console.warn(`[payments/initiate] rate limited user ${sub}`);
    return tooManyRequests("Too many subscription attempts — please wait a minute");
  }

  let body: { plan?: string; appInstanceId?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { plan } = body;
  // v1 sells monthly only — deliberate. "yearly" is accepted for schema
  // compatibility and maps to monthly until a yearly plan actually exists.
  if (plan !== "monthly" && plan !== "yearly") {
    return errorResponse(400, "invalid_plan", "plan must be 'monthly' or 'yearly'");
  }

  // Firebase app_instance_id, refreshed at the moment it matters most: the
  // debits this mandate will produce settle app-closed, and lib/ga4.ts can only
  // attribute them if the id is on the users row. /auth/login also uploads it,
  // but a user who signed in on an older build reaches here without one.
  const appInstanceId = normalizeAppInstanceId(body.appInstanceId);

  const sql = getDb(env);
  try {
    if (appInstanceId) {
      await sql`
        UPDATE users SET app_instance_id = ${appInstanceId}::text
        WHERE id = ${sub}
      `;
    }
    // ── One free trial per user ────────────────────────────────────────────
    // trial_end is written exactly once — the first time a mandate setup
    // completes (webhook/reconcile COALESCE it, never overwrite). So a non-null
    // trial_end means this user already consumed their trial: authorize the new
    // mandate with a REAL ₹199 first debit (TRANSACTION) instead of the ₹2
    // PENNY_DROP, and skip the trial on completion.
    // Build the IDs up front — the claim below writes them before PhonePe is
    // called, so a concurrent request can see that a setup is already underway.
    const merchantSubscriptionId = buildMerchantSubscriptionId(sub);
    const merchantOrderId = buildMerchantOrderId(sub, "S");

    // ── Serialize every initiate for this user ─────────────────────────────
    //
    // Read-then-call-PhonePe-then-write let two concurrent initiates both read
    // the SAME prior row, both create a mandate, and the second overwrite the
    // first's merchant_subscription_id — leaving mandate #1 live at PhonePe with
    // no pointer in our DB. Its webhook then matches no row
    // ("Setup completed for UNKNOWN sub …" → 200 OK, no grant, no PhonePe
    // retry), and /payments/cancel and DELETE /me can never revoke it because
    // both look the id up from the row. Reproduced 2026-07-27.
    //
    // The lock is taken on the USERS row, not the subscriptions row: a
    // first-time subscriber has no subscriptions row yet, so FOR UPDATE there
    // would lock nothing and the very race we care about would slip through.
    //
    // Inside the lock we do three things atomically: re-read the prior row,
    // refuse a setup that is already in flight, and CLAIM the new ids. Claiming
    // before the PhonePe call is what makes the in-flight check work — the
    // marker has to be visible to the second request while the first is still
    // waiting on PhonePe.
    const claim = (await sql.begin(async (tx) => {
      await tx`SELECT 1 FROM users WHERE id = ${sub} FOR UPDATE`;

      const prior = await tx<PriorSubscription[]>`
        SELECT trial_end, status, merchant_subscription_id, current_period_end,
               updated_at
        FROM subscriptions WHERE user_id = ${sub} LIMIT 1
      `;
      const existing = prior[0] ?? null;

      const priorPeriodEnd = toDate(existing?.current_period_end);
      const hasLivePeriod =
        priorPeriodEnd !== null && priorPeriodEnd.getTime() > Date.now();
      if (
        existing &&
        (existing.status === "trialing" || existing.status === "active") &&
        hasLivePeriod
      ) {
        return { conflict: "active_subscription" } as ClaimResult;
      }

      // A pending row touched moments ago means another request is mid-setup —
      // a double-tap that beat the client's own CTA disable, a client-side
      // timeout retry whose first attempt actually succeeded, or a relaunch
      // mid-flow. Refuse rather than authorize a second mandate; the caller
      // retries and gets the settled state.
      const claimedAt = toDate(existing?.updated_at);
      if (
        existing &&
        existing.status === "pending" &&
        claimedAt !== null &&
        Date.now() - claimedAt.getTime() < SETUP_CLAIM_WINDOW_MS
      ) {
        return { conflict: "setup_in_flight" } as ClaimResult;
      }

      // Whatever mandate this row pointed at is about to become unreachable.
      // Capture it under the lock so a losing concurrent request revokes the
      // WINNER's mandate rather than an id it read before the race started.
      const superseded =
        existing && existing.merchant_subscription_id && existing.status !== "cancelled"
          ? existing.merchant_subscription_id
          : null;

      await tx`
        INSERT INTO subscriptions (
          user_id, status, plan, merchant_subscription_id, merchant_order_id
        )
        VALUES (
          ${sub}, 'pending', ${plan}, ${merchantSubscriptionId}, ${merchantOrderId}
        )
        ON CONFLICT (user_id)
        DO UPDATE SET
          status                   = 'pending',
          plan                     = EXCLUDED.plan,
          merchant_subscription_id = EXCLUDED.merchant_subscription_id,
          merchant_order_id        = EXCLUDED.merchant_order_id,
          phonepe_order_id         = NULL,
          updated_at               = now()
      `;

      return {
        conflict: false,
        supersededMandateId: superseded,
        trialEligible: existing === null || existing.trial_end === null,
      } as ClaimResult;
    })) as unknown as ClaimResult;

    if (claim.conflict === "setup_in_flight") {
      // Distinct code on purpose: the app turns `already_subscribed` into a
      // SUCCESS state, which would be a lie here — nothing has been authorized
      // yet. See ClaimConflict.
      return errorResponse(
        409,
        "setup_in_progress",
        "A payment setup is already in progress. Please wait a moment and try again.",
      );
    }
    if (claim.conflict) {
      return errorResponse(
        409,
        "already_subscribed",
        "You already have an active subscription",
      );
    }

    const { supersededMandateId, trialEligible } = claim;

    // Redirect URL PhonePe sends the user back to after mandate authorization.
    // Derive the origin from the incoming request so it always matches the host
    // the app actually called — both arul-api.hsrutility.com and the legacy
    // workers.dev host serve live builds, so a hardcode would break one of them.
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

    // Diagnostic for the PR004/Unauthorized class of on-device failure. The SDK
    // authenticates with merchantId + token, and the Worker validates NEITHER —
    // a wrong merchant id or a web-checkout token both still return 200 here and
    // only blow up inside the SDK. Log their shape (never their value) so the
    // next failed tap says which one is wrong.
    console.log(
      `[payments/initiate] env=${env.PHONEPE_ENV} ` +
        `merchantIdLen=${env.PHONEPE_MERCHANT_ID?.length ?? 0} ` +
        `merchantIdPrefix=${(env.PHONEPE_MERCHANT_ID ?? "").slice(0, 4)} ` +
        `tokenLen=${ppResult.token?.length ?? 0} ` +
        `orderId=${ppResult.orderId} state=${ppResult.state} ` +
        `trialEligible=${trialEligible}`,
    );

    // Attach PhonePe's order id to the row we already claimed above.
    //
    // Scoped to the claimed merchant_order_id: if a later initiate has already
    // superseded this claim while PhonePe was answering, this UPDATE must not
    // stamp a stale order id onto the newer mandate. Zero rows updated is the
    // correct outcome there — the newer request owns the row.
    await sql`
      UPDATE subscriptions
      SET phonepe_order_id = ${ppResult.orderId},
          updated_at       = now()
      WHERE user_id = ${sub}
        AND merchant_order_id = ${merchantOrderId}
    `;

    // The mandate this row pointed at before the claim is now unreferenced —
    // revoke it so the user can never end up with two live mandates debiting
    // them. Captured under the user-row lock, so in a genuine race this is the
    // OTHER request's mandate, not a pre-race snapshot. Best-effort and OFF the
    // response path: a PhonePe hiccup must never break a legitimate retry.
    if (supersededMandateId && supersededMandateId !== merchantSubscriptionId) {
      const staleMandateId: string = supersededMandateId;
      c.executionCtx.waitUntil(
        revokeMandateTolerant(env, staleMandateId)
          .then((revoked) => {
            if (!revoked) {
              console.error(
                `[payments/initiate] Superseded mandate ${staleMandateId} may STILL BE LIVE at PhonePe — manual revoke required`,
              );
            }
          })
          .catch((err: unknown) => {
            console.error(
              `[payments/initiate] Revoke of superseded mandate ${staleMandateId} threw:`,
              err,
            );
          }),
      );
    }

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
      // Trimmed: the SDK authenticates with this verbatim, and a trailing
      // newline here surfaces on-device as PR004 "Unauthorized" with a healthy
      // 200 from us — the hardest possible bug to trace.
      merchantId: env.PHONEPE_MERCHANT_ID.trim(),
      // Trimmed for the same reason. isProduction() trims before choosing the
      // host, so an untrimmed value here would route the Worker to the RIGHT
      // host while the app inits the SDK with "PRODUCTION\n" — the two would
      // silently disagree. The client rejects an empty/missing value outright.
      environment: env.PHONEPE_ENV.trim(),
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

  // Read the body ONCE, before the auth check, so a rejected delivery can still
  // be described in the logs (see below). c.req.text() cannot be called twice.
  const rawBody = await c.req.text();

  const authValid = await verifyCallbackAuth(authHeader, webhookUsername, webhookPassword);
  if (!authValid) {
    // LOUD on purpose. This path used to return 401 silently, which made two
    // very different situations look identical from the outside: "PhonePe has
    // never sent us anything" and "PhonePe is sending everything and we are
    // rejecting all of it because the dashboard credentials don't match our
    // secrets". Both produce zero DB writes, zero KV idempotency marks and zero
    // log lines — so a totally broken webhook is indistinguishable from an idle
    // one, and stays that way until someone notices renewals aren't landing.
    //
    // Deliberately logs SHAPE, never content: whether a header arrived, its
    // length, and whether it looks like the expected 64-char lowercase hex of
    // SHA256(username:password). Never the header itself, and never the
    // configured credentials — the log is not a place to leak either.
    //
    // Mirrored in Pakiza (workers/src/routes/payments.ts) — keep both in sync.
    const looksLikeSha256Hex = /^[0-9a-f]{64}$/.test(authHeader.trim());
    let eventPeek = "<unparseable>";
    try {
      const peek = JSON.parse(rawBody) as PhonePeWebhookPayload;
      eventPeek =
        `${peek.event ?? peek.type ?? "?"} sub=${peek.payload?.merchantSubscriptionId ?? "?"}`;
    } catch {
      // leave the placeholder
    }
    console.error(
      `[payments/webhook] REJECTED a delivery on auth. ` +
      `authHeader present=${authHeader.length > 0} len=${authHeader.length} ` +
      `sha256HexShaped=${looksLikeSha256Hex} event=${eventPeek}. ` +
      `If this is PhonePe, the dashboard's webhook username/password do not match ` +
      `PHONEPE_WEBHOOK_USERNAME/PHONEPE_WEBHOOK_PASSWORD on this Worker.`,
    );
    return errorResponse(401, "invalid_signature", "Webhook authorization failed");
  }

  // 2. Parse payload
  let payload: PhonePeWebhookPayload;
  try {
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

  // 3. Idempotency — dedupe on (event, PhonePe orderId).
  //
  // The EVENT MUST be part of the key. One redemption cycle reuses a single
  // merchantOrderId across notify + redeem, so PhonePe emits several distinct
  // events carrying the SAME orderId:
  //   subscription.notification.completed         (not handled here)
  //   subscription.redemption.order.completed     (the one that grants the month)
  //   subscription.redemption.transaction.completed
  // With an order-only key the first arrival — typically the unhandled
  // notification event — burned the slot and every later event for that order
  // was dropped as "already processed", so the debit-success handler never ran:
  // status stayed 'trialing', current_period_end never extended, and the
  // referral reward never granted. Scoping the key per event keeps genuine
  // duplicate DELIVERIES of the same event deduped (PhonePe's retry) while
  // letting each distinct event be processed exactly once.
  const dedupeKey = pp.orderId ?? pp.merchantOrderId ?? "";
  if (!dedupeKey) {
    console.error("[payments/webhook] Missing orderId/merchantOrderId, event:", event);
    return new Response("ok", { status: 200 });
  }

  const kvKey = `txn:${event}:${dedupeKey}`;
  const alreadyProcessed = await env.KV.get(kvKey);
  if (alreadyProcessed) {
    console.log(`[payments/webhook] Already processed ${dedupeKey}, event: ${event}`);
    return new Response("ok", { status: 200 });
  }

  const merchantSubId = pp.merchantSubscriptionId;
  if (!merchantSubId) {
    // Deliberately NO idempotency mark. Marking an unactionable payload
    // processed permanently consumes the (event, orderId) slot, so a corrected
    // redelivery of that same event could never be handled by anyone. Ack 200
    // (there is nothing here to act on) but leave the slot free.
    console.error(
      `[payments/webhook] Missing merchantSubscriptionId — not marking processed. ` +
      `event=${event} order=${dedupeKey}`,
    );
    return new Response("ok", { status: 200 });
  }

  // Belt and braces on the CMS dispatcher's prefix routing: Arul's merchant ids
  // are "DKS_"-prefixed, and the dispatcher sends everything ELSE to Pakiza. A
  // non-DKS id arriving here means it misrouted — refuse loudly rather than
  // matching zero rows and silently acking, which looked identical to success.
  if (!merchantSubId.startsWith("DKS_")) {
    console.error(
      `[payments/webhook] merchantSubscriptionId ${merchantSubId} is not an Arul id — ` +
      `misrouted by the dispatcher; not processing and not marking`,
    );
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

      // `AND status = 'pending'` is LOAD-BEARING — do not drop it.
      //
      // The trial/paid decision reads the row's OWN trial_end, and the app's
      // /payments/status poll runs the identical reconcile the moment the SDK
      // returns. Whichever lands first writes trial_end. Without this guard the
      // second one then re-reads that just-written trial_end, concludes "trial
      // already consumed → repeat subscriber", and hands out `active` + a FULL
      // MONTH of premium + a referral reward — all off a ₹2 PENNY_DROP that
      // charged the user nothing. The reconcile path has always been scoped to
      // pending (see handleStatus); this branch was the unguarded half.
      //
      // KV dedupe does not cover this: the two writers are the webhook and the
      // app poll, which share no dedupe key at all.
      //
      // COALESCE on phonepe_subscription_id so a payload that omits
      // subscriptionId can never blank an id we already hold.
      const updated = await sql<{ user_id: string; status: string }[]>`
        UPDATE subscriptions
        SET status                   = CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END,
            phonepe_subscription_id  = COALESCE(${phonepeSubId}, phonepe_subscription_id),
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
          AND status = 'pending'
        RETURNING user_id, status
      `;

      const row = updated[0];

      if (!row) {
        // Either the poll already reconciled this exact setup (the common,
        // entirely benign case) or the id matches nothing. Both are no-ops for
        // state, but they are NOT the same operationally, so say which.
        //
        // We do still backfill phonepe_subscription_id when it is NULL: the
        // reconcile path can only read it from the order-status response, which
        // does not always carry paymentFlow.subscriptionId, whereas the webhook
        // payload does. That write is idempotent, has no financial effect, and
        // is the only field the guard above would otherwise strand empty.
        // The ::text casts are LOAD-BEARING. postgres.js runs with
        // fetch_types:false (required for Hyperdrive), so a bare parameter that
        // appears only inside `${x} IS NOT NULL` gives Postgres no context to
        // infer its type and the whole statement fails with
        //   "could not determine data type of parameter $2".
        // That threw here for EVERY checkout.order.completed whose row was not
        // 'pending' — i.e. the common case where the app's /payments/status poll
        // reconciled first — and the catch below turns it into a 500, so PhonePe
        // retried a delivery that had in fact nothing left to do.
        const diag = await sql<{ status: string; had_sub_id: boolean }[]>`
          UPDATE subscriptions
          SET phonepe_subscription_id = COALESCE(phonepe_subscription_id, ${phonepeSubId}::text),
              updated_at              = CASE
                                          WHEN phonepe_subscription_id IS NULL AND ${phonepeSubId}::text IS NOT NULL
                                          THEN now() ELSE updated_at
                                        END
          WHERE merchant_subscription_id = ${merchantSubId}
          RETURNING status, (phonepe_subscription_id IS NOT NULL) AS had_sub_id
        `;
        if (diag.length === 0) {
          console.error(
            `[payments/webhook] Setup completed for UNKNOWN sub ${merchantSubId} — no such row`,
          );
        } else {
          console.log(
            `[payments/webhook] Setup completed for sub ${merchantSubId} but row is ` +
            `'${diag[0].status}', not 'pending' — already reconciled by the status poll; ` +
            `no state change (phonepe_subscription_id present=${diag[0].had_sub_id})`,
          );
        }
      } else {
        console.log(
          `[payments/webhook] Setup completed for sub ${merchantSubId} → ` +
          `${row.status}, amount=${pp.amount ?? "?"}`,
        );
      }

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
        // Server-side settle → the app is closed, no client event exists. The
        // order+transaction event pair and any cron double-settle collapse via
        // the transaction-id dedupe inside. Fail-open — never blocks the grant.
        await reportServerPurchase(env, sql, {
          userId: activated[0].user_id as string,
          transactionId: (pp.merchantOrderId ?? pp.orderId) as string,
          amountPaise: typeof pp.amount === "number" ? pp.amount : null,
        });
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
    // 500 so PhonePe RETRIES. A transient Hyperdrive/Neon fault on
    // checkout.order.completed used to be acked 200 here — the user had paid,
    // the row never updated, and the event was gone forever with no
    // dead-letter. Retrying is safe precisely because the idempotency mark
    // above is written ONLY on the success path, so a redelivery re-runs the
    // handler from a clean slate and lands exactly one state transition.
    return errorResponse(500, "server_error", "Temporary failure — please retry");
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
          const updated = await sql<
            {
              user_id: string;
              status: string;
              trial_end: unknown;
              current_period_end: unknown;
              next_debit_at: unknown;
            }[]
          >`
            UPDATE subscriptions
            SET status                   = CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END,
                phonepe_subscription_id  = COALESCE(${phonepeSubId}, phonepe_subscription_id),
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
            RETURNING user_id, status, trial_end, current_period_end, next_debit_at
          `;
          if (updated[0]) {
            // Copy the FRESH values back onto `row` — the response below is built
            // from the SELECT taken before this UPDATE, so without this the app
            // was told status='trialing'/'active' while trial_end,
            // current_period_end and next_debit_at were still the pre-reconcile
            // values (null on a first setup). That is the one response that
            // confirms a purchase, and it carried no period at all.
            row.status = updated[0].status;
            row.trial_end = updated[0].trial_end;
            row.current_period_end = updated[0].current_period_end;
            row.next_debit_at = updated[0].next_debit_at;
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
          // Mirror the write so the response can't claim a debit is still coming
          // on a mandate we just recorded as revoked.
          row.next_debit_at = null;
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
