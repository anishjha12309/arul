/**
 * Payment routes — PhonePe Standard Checkout v2 (OAuth / O-Bearer). /payments/webhook is the only un-JWT'd one.
 *
 * ONE FREE TRIAL PER USER, and `trial_end` is the consumed-marker -> it is written exactly ONCE, never overwritten
 * trial_end NULL -> trial-eligible -> PENNY_DROP setup, ₹2 auto-reversed by PhonePe
 * trial_end NOT NULL -> trial consumed -> TRANSACTION setup, a REAL ₹199 first debit at setup time
 * A completed first setup lands 'trialing'; a completed repeat setup lands 'active', already charged
 * The autopay cron then notifies 24h ahead and executes at next_debit_at -> success extends a month
 * Webhook events are deduped by the KV key "txn:<orderId>" -> PhonePe redelivers, so every write must be idempotent
 * The webhook is authenticated by a header equal to SHA256(username + ":" + password) -> there is no body signature
 * Every response shape here is parsed by the shipped Flutter models -> a renamed key breaks installs that never update
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { getDb, toDate } from "../lib/db.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  reportPostHogFirstConversion,
  reportPostHogSubscriptionCancel,
} from "../lib/posthog.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
import {
  setupSubscription,
  setupSubscriptionIntent,
  revokeMandateTolerant,
  verifyCallbackAuth,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantSubscriptionId,
  buildMerchantOrderId,
  type PhonePeWebhookPayload,
  merchantSubscriptionIdOf,
  phonePeSubscriptionIdOf,
} from "../lib/phonepe.js";

const KV_TXN_TTL = 30 * 24 * 60 * 60; // 30 days — covers PhonePe's retry window

/** Monthly price in paise -> must match maxAmount in phonepe.ts -> a mismatch makes the mandate refuse the debit. */
const MONTHLY_PRICE_PAISE = 19900;

/**
 * Free-trial length. The ₹2 PENNY_DROP only AUTHORIZES the mandate — the trial itself is ours.
 *
 * Both the webhook and the /payments/status reconcile grant it -> they MUST agree -> one constant, never two literals
 * A drift gives two users different trials depending on which path confirmed their mandate first
 * It is also the debit clock -> next_debit_at = now + this -> the paywall copy must say the same number
 */
const TRIAL_DAYS = 1;
const TRIAL_MS = TRIAL_DAYS * 24 * 60 * 60 * 1000;

/**
 * How long a claimed-but-unfinished mandate setup blocks a second attempt.
 *
 * It only needs to outlive the PhonePe setup call itself, observed at 1-3 s
 * The users-row lock serializes concurrent initiates, and /payments/abandon releases a claim the moment the SDK returns
 * This window is the backstop for attempts that CANNOT abandon -> app killed at the sheet, network gone mid-flow
 * Every second here is a second a returning user stares at "setup in progress" -> at 15 s a double-tap surfaced it
 * PAIRED with the client's silent retries -> their delays SUM to this window
 * So by the final retry a claim born before the first attempt has provably lapsed -> only a concurrent attempt refuses
 * Change either side and re-check that sum(retry delays) >= this window
 */
const SETUP_CLAIM_WINDOW_MS = 4_000;

/** The columns handleInitiate reads under the per-user lock. */
interface PriorSubscription {
  trial_end: unknown;
  status: string;
  merchant_subscription_id: string | null;
  current_period_end: unknown;
  updated_at: unknown;
}

/**
 * Why a claim was refused. The two reasons MUST stay distinguishable all the way out to the client.
 *
 * "You already pay us" is a SUCCESS the app celebrates -> it flips to Manage Subscription
 * "Your own setup is still running" is a TRANSIENT retry -> the app tries again
 * Answering the second with the first told a double-tapping user their purchase succeeded when NO mandate existed
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

  // Every call creates a REAL PhonePe mandate-setup order -> keyed by user, so one account cannot burn the API quota
  if (!(await allowRequest(env.RL_PAYMENTS, `initiate:${sub}`))) {
    console.warn(`[payments/initiate] rate limited user ${sub}`);
    return tooManyRequests("Too many subscription attempts — please wait a minute");
  }

  let body: { plan?: string; targetApp?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { plan } = body;
  // v1 sells monthly ONLY -> "yearly" is accepted for schema compatibility and maps to monthly until one exists
  if (plan !== "monthly" && plan !== "yearly") {
    return errorResponse(400, "invalid_plan", "plan must be 'monthly' or 'yearly'");
  }

  // Direct UPI-intent flow, additive and opt-in -> the app sends the package of the UPI app the user picked
  // It gets back an intentUrl opening that app straight on its mandate sheet -> no hosted PAY_PAGE at all
  // Absent or malformed -> the SDK page flow, exactly as before -> old builds are untouched
  // Shape check only -> PhonePe validates the package itself -> do not maintain an allow-list here
  const targetApp =
    typeof body.targetApp === "string" &&
    /^[a-zA-Z][a-zA-Z0-9._]{2,100}$/.test(body.targetApp)
      ? body.targetApp
      : null;

  const sql = getDb(env);
  try {
    // ── One free trial per user ────────────────────────────────────────────
    // trial_end is written EXACTLY ONCE, at the first completed setup -> webhook and reconcile COALESCE, never overwrite
    // So a non-null trial_end means the trial is consumed -> authorize with a REAL ₹199 TRANSACTION, not a PENNY_DROP
    // Build the ids up front -> the claim below writes them BEFORE PhonePe is called
    // That is what lets a concurrent request see a setup is already underway
    const merchantSubscriptionId = buildMerchantSubscriptionId(sub);
    const merchantOrderId = buildMerchantOrderId(sub, "S");

    // ── Serialize every initiate for this user ─────────────────────────────
    // Read-then-call-PhonePe-then-write let two concurrent initiates read the SAME prior row and both create a mandate
    // The second then overwrote the first's merchant_subscription_id -> mandate #1 stayed live at PhonePe, unreferenced
    // Its webhook matched no row -> 200 OK, no grant, no PhonePe retry -> the debit had nowhere to land
    // And /payments/cancel and DELETE /me could never revoke it -> both look the id up from the row
    // The lock is on the USERS row, NOT subscriptions -> a first-time subscriber has no subscriptions row to lock
    // FOR UPDATE there would lock nothing and the exact race would slip through
    // Inside the lock, three things happen atomically: re-read the prior row, refuse an in-flight setup, CLAIM the new ids
    // Claiming BEFORE the PhonePe call is what makes the in-flight check work at all
    // The marker must be visible to the second request while the first is still waiting on PhonePe
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

      // A pending row touched moments ago means another request is MID-SETUP -> refuse, never authorize a second mandate
      // Its causes: a double-tap that beat the CTA disable, a timeout retry whose first attempt succeeded, a relaunch
      // The caller retries and gets the settled state -> refusing costs a retry, authorizing costs a stranded mandate
      const claimedAt = toDate(existing?.updated_at);
      if (
        existing &&
        existing.status === "pending" &&
        claimedAt !== null &&
        Date.now() - claimedAt.getTime() < SETUP_CLAIM_WINDOW_MS
      ) {
        return { conflict: "setup_in_flight" } as ClaimResult;
      }

      // Whatever mandate this row pointed at is about to become unreachable -> capture it UNDER the lock
      // Otherwise a losing concurrent request revokes the WINNER's mandate, using an id it read before the race
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
      // A DISTINCT code on purpose -> the app turns `already_subscribed` into a SUCCESS state
      // Nothing has been authorized here yet -> reusing that code would be a lie -> see ClaimConflict
      return errorResponse(
        409,
        "setup_in_progress",
        "A payment setup is already in progress. Please wait a few seconds and try again.",
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

    // Attach PhonePe's order id to the row already claimed above, SCOPED to the claimed merchant_order_id
    // A later initiate may have superseded this claim while PhonePe answered -> this must not stamp the newer mandate
    // Zero rows updated is the CORRECT outcome there -> the newer request owns the row
    const attachPhonePeOrder = async (phonepeOrderId: string) => {
      await sql`
        UPDATE subscriptions
        SET phonepe_order_id = ${phonepeOrderId},
            updated_at       = now()
        WHERE user_id = ${sub}
          AND merchant_order_id = ${merchantOrderId}
      `;
    };

    // The mandate this row pointed at before the claim is now unreferenced -> revoke it
    // Otherwise the user ends up with TWO live mandates debiting them -> that is the failure this prevents
    // Captured under the user-row lock -> in a real race this is the OTHER request's mandate, not a pre-race snapshot
    // Best-effort and OFF the response path -> a PhonePe hiccup must never break a legitimate retry
    const revokeSuperseded = () => {
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
    };

    // ── Direct UPI-intent path (app sent targetApp) ────────────────────────
    // Falls back to the SDK setup below on ANY failure, reusing the SAME claimed ids
    // A second initiate here would bounce off its own SETUP_CLAIM_WINDOW_MS -> reuse is the only workable path
    // Accepted edge: a 200 without an intentUrl leaves an order at PhonePe under this merchantOrderId
    // The sdk/order fallback may then 409/400 -> the user's next tap supersedes it cleanly
    if (targetApp) {
      try {
        const intent = await setupSubscriptionIntent(env, {
          merchantOrderId,
          merchantSubscriptionId,
          targetApp,
          upfrontAmountPaise: trialEligible ? undefined : MONTHLY_PRICE_PAISE,
        });
        await attachPhonePeOrder(intent.orderId);
        revokeSuperseded();
        console.log(
          `[payments/initiate] env=${env.PHONEPE_ENV} flow=intent target=${targetApp} ` +
            `orderId=${intent.orderId} state=${intent.state} trialEligible=${trialEligible}`,
        );
        return c.json({
          flow: "intent",
          merchantSubscriptionId,
          merchantOrderId,
          orderId: intent.orderId,
          state: intent.state,
          intentUrl: intent.intentUrl,
          trialEligible,
          amountPaise: trialEligible ? 200 : MONTHLY_PRICE_PAISE,
        });
      } catch (intentErr) {
        console.warn(
          `[payments/initiate] intent setup failed for ${targetApp} — falling back to SDK page:`,
          intentErr,
        );
      }
    }

    // Where PhonePe sends the user back after authorization -> derive the origin from the INCOMING request
    // Both the custom domain and the legacy workers.dev host serve live builds -> a hardcode breaks one of them
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

    // Diagnostic for the PR004/Unauthorized class of on-device failure -> the SDK authenticates with merchantId + token
    // The Worker validates NEITHER -> a wrong merchant id or a web-checkout token both still return 200 from here
    // They only blow up inside the SDK -> log their SHAPE, never their value, so the next failed tap names the culprit
    console.log(
      `[payments/initiate] env=${env.PHONEPE_ENV} ` +
        `merchantIdLen=${env.PHONEPE_MERCHANT_ID?.length ?? 0} ` +
        `merchantIdPrefix=${(env.PHONEPE_MERCHANT_ID ?? "").slice(0, 4)} ` +
        `tokenLen=${ppResult.token?.length ?? 0} ` +
        `orderId=${ppResult.orderId} state=${ppResult.state} ` +
        `trialEligible=${trialEligible}`,
    );

    await attachPhonePeOrder(ppResult.orderId);
    revokeSuperseded();

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
    // LOUD on purpose -> a silent 401 made two very different situations look identical from outside
    // "PhonePe never sent us anything" and "PhonePe sends everything and our credentials reject all of it"
    // Both produce zero DB writes, zero KV marks and zero log lines -> a broken webhook reads exactly like an idle one
    // It stays that way until someone notices renewals are not landing -> log the failure, loudly
    // Log SHAPE, never content -> whether a header arrived, its length, whether it looks like 64-char lowercase hex
    // Never the header itself and never the configured credentials -> a log is not a place to leak either
    // Mirrored in Pakiza's workers/src/routes/payments.ts -> keep both in sync
    const looksLikeSha256Hex = /^[0-9a-f]{64}$/.test(authHeader.trim());
    let eventPeek = "<unparseable>";
    try {
      const peek = JSON.parse(rawBody) as PhonePeWebhookPayload;
      eventPeek =
        `${peek.event ?? peek.type ?? "?"} sub=${merchantSubscriptionIdOf(peek.payload) ?? "?"}`;
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

  // PhonePe's docs are inconsistent about the field name AND its casing -> some show dotted-lower, others UPPER_SNAKE
  // Normalize both to the dotted-lower form so the switch below matches whichever arrives -> lower, then "_" to "."
  const rawEvent = payload.event ?? payload.type ?? "";
  const event = rawEvent.toLowerCase().replace(/_/g, ".");
  const pp = payload.payload ?? {};

  // 3. Idempotency — dedupe on (event, PhonePe orderId). The EVENT MUST be part of the key
  // One redemption cycle reuses a single merchantOrderId across notify and redeem
  // So PhonePe emits several DISTINCT events carrying the SAME orderId -> notification, order, transaction
  // With an order-only key the first arrival burned the slot -> usually the unhandled notification event
  // Every later event for that order was then dropped as "already processed" -> the debit-success handler never ran
  // status stayed 'trialing', the period never extended, the referral reward never granted
  // Scoping per event still dedupes a genuine duplicate DELIVERY -> each distinct event is processed exactly once
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

  const merchantSubId = merchantSubscriptionIdOf(pp);
  if (!merchantSubId) {
    // Deliberately NO idempotency mark -> marking an unactionable payload consumes the (event, orderId) slot forever
    // A corrected redelivery of that same event could then never be handled -> ack 200, but leave the slot free
    console.error(
      `[payments/webhook] Missing merchantSubscriptionId — not marking processed. ` +
      `event=${event} order=${dedupeKey}`,
    );
    return new Response("ok", { status: 200 });
  }

  // Belt and braces on the dispatcher's prefix routing -> Arul's merchant ids are "DKS_", everything else is Pakiza's
  // A non-DKS id arriving here means it MISROUTED -> refuse loudly
  // Matching zero rows and acking silently looked identical to success -> that is how a misroute hides
  if (!merchantSubId.startsWith("DKS_")) {
    console.error(
      `[payments/webhook] merchantSubscriptionId ${merchantSubId} is not an Arul id — ` +
      `misrouted by the dispatcher; not processing and not marking`,
    );
    return new Response("ok", { status: 200 });
  }

  const sql = getDb(env);
  try {
    // 4. Route by event type. Setup success arrives under TWO names, one per setup surface
    // The SDK/hosted-page flow emits checkout.order.completed; the UPI-intent flow emits subscription.setup.order.completed
    // Identical meaning and identical payload nesting -> both must route to the SAME grant
    // The dashboard webhook must have the subscription.setup.order.* events SELECTED or PhonePe never sends them
    if (
      event === "checkout.order.completed" ||
      event === "subscription.setup.order.completed"
    ) {
      // Mandate setup succeeded. ONE FREE TRIAL PER USER, decided off trial_end
      // trial_end IS NULL -> first ever setup -> 'trialing' plus the free trial
      // trial_end NOT NULL -> initiate authorized this mandate with a real ₹199 TRANSACTION -> 'active' for a month
      // The CASE expressions read the row's OLD trial_end under Postgres SET semantics -> decide and write in ONE statement
      // COALESCE keeps the ORIGINAL trial_end forever -> that column is the consumed-marker, not a date to refresh
      const trialEnd = new Date(Date.now() + TRIAL_MS);
      const paidEnd = addOneMonth(new Date());
      const phonepeSubId = phonePeSubscriptionIdOf(pp);

      // `AND status = 'pending'` is LOAD-BEARING -> never drop it
      // The trial/paid decision reads the row's OWN trial_end, and the app's status poll runs the identical reconcile
      // Whichever lands first writes trial_end -> the second then re-reads it and concludes "repeat subscriber"
      // It would hand out 'active', a FULL MONTH of premium and a referral reward off a ₹2 PENNY_DROP
      // The reconcile path was always scoped to pending -> this branch was the unguarded half
      // KV dedupe cannot cover it -> the two writers are the webhook and the app poll, which share no key
      // COALESCE on phonepe_subscription_id -> a payload that omits subscriptionId must never blank an id we hold
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

      let row = updated[0];

      if (!row) {
        // The app auto-resolves an intent setup the user walked away from -> that can RACE a genuine approval by seconds
        // Abandon leaves the row 'expired', or 'cancelled' when it restored a still-paid period
        // The user PAID -> a ₹199 TRANSACTION, or an authorized trial mandate -> refusing the grant eats real money
        // So resurrect, scoped to the EXACT ids of THIS event and only those two post-abandon statuses
        // An OLD dunning-expired or user-cancelled subscription can never match -> fresh setups carry fresh ids
        // And this order's own completion was KV-deduped at setup time -> only the abandon-raced claim qualifies
        // 'cancelled' is in the list for the restore rule -> without it a late-landing approval swallows a real ₹199
        const resurrected = await sql<{ user_id: string; status: string }[]>`
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
            AND merchant_order_id = ${pp.merchantOrderId ?? ""}
            AND status IN ('expired', 'cancelled')
          RETURNING user_id, status
        `;
        if (resurrected[0]) {
          row = resurrected[0];
          console.log(
            `[payments/webhook] Setup completed for sub ${merchantSubId} — ` +
            `RESURRECTED an abandon-expired claim (approval raced the auto-cancel); grant applied`,
          );
        }
      }

      if (!row) {
        // Either the poll already reconciled this exact setup, the common benign case, or the id matches nothing
        // Both are state no-ops but they are NOT the same operationally -> the log must say which
        // phonepe_subscription_id is still backfilled when NULL -> the reconcile path reads it from order-status
        // That response does not always carry paymentFlow.subscriptionId, whereas the webhook payload does
        // The write is idempotent with no financial effect -> it is the only field the guard above would strand empty
        // The ::text casts are LOAD-BEARING -> `fetch_types:false` gives Postgres no type context for a bare parameter
        // A parameter appearing only inside `${x} IS NOT NULL` then fails the whole statement on type inference
        // That threw for EVERY completed setup whose row was not 'pending' -> the common poll-reconciled-first case
        // The catch below turned it into a 500 -> PhonePe retried a delivery with nothing left to do
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
        // A repeat subscriber paid ₹199 at setup -> that IS a paid debit -> the referral reward applies here too
        await grantReferralReward(sql, row.user_id);
        // Audit -> a repeat subscriber's setup order must carry the REAL charge
        // amount=200 here means a stale PENNY_DROP order completed for a trial-consumed user
        if (typeof pp.amount === "number" && pp.amount < MONTHLY_PRICE_PAISE) {
          console.warn(
            `[payments/webhook] Trial-consumed user activated via setup order of only ${pp.amount} paise (sub ${merchantSubId})`,
          );
        }
      }

    } else if (
      event === "checkout.order.failed" ||
      event === "subscription.setup.order.failed"
    ) {
      // Mandate setup failed, on either setup surface -> RESTORE, never simply expire
      // A resubscribe rides over the user's ONE row -> at claim time a cancelled-but-still-paid row became 'pending'
      // Flipping a failed attempt to 'expired' therefore STRIPPED days the user had already paid for
      // While current_period_end is still ahead the correct post-failure state is 'cancelled'
      // That is entitled to what they paid for, with no future debits -> exactly where they stood before Resubscribe
      await sql`
        UPDATE subscriptions
        SET status     = CASE WHEN current_period_end IS NOT NULL AND current_period_end > now()
                              THEN 'cancelled' ELSE 'expired' END,
            updated_at = now()
        WHERE merchant_subscription_id = ${merchantSubId}
          AND status = 'pending'
      `;

    } else if (
      event === "subscription.redemption.order.completed" ||
      event === "subscription.redemption.transaction.completed"
    ) {
      // Debit succeeded -> move to active and extend the period by a month
      // The self-join FROM reads the row's PRE-UPDATE snapshot -> the only place the prior status still exists
      // 'trialing' at settle = the FIRST trial->paid conversion; 'active' = a renewal
      // Every SET and WHERE column is qualified -> both aliases expose the same column names
      const nextEnd = addOneMonth(new Date());
      const phonepeSubId = phonePeSubscriptionIdOf(pp);

      const activated = await sql<
        { user_id: string; prior_status: string; updated_at?: Date | string | null }[]
      >`
        UPDATE subscriptions AS s
        SET status                  = 'active',
            phonepe_subscription_id = COALESCE(${phonepeSubId}, s.phonepe_subscription_id),
            current_period_end      = ${nextEnd.toISOString()},
            next_debit_at           = ${nextEnd.toISOString()},
            notified_at             = NULL,
            retry_count             = 0,
            updated_at              = now()
        FROM subscriptions AS prior
        WHERE s.merchant_subscription_id = ${merchantSubId}
          AND prior.id = s.id
        RETURNING s.user_id, prior.status AS prior_status, s.updated_at
      `;

      console.log(`[payments/webhook] Active for sub ${merchantSubId}, period_end=${nextEnd.toISOString()}`);

      // Referral reward -> this user just made a paid debit -> only the FIRST ever grants, via the status<>'rewarded' guard
      if (activated.length > 0) {
        await grantReferralReward(sql, activated[0].user_id);
        // NO ad-platform conversion is reported from the server -> GA4 `purchase` and Meta `Subscribe` are BOTH gone
        // One conversion action fed by two source types desynchronises attribution -> see cron/autopay-notify.ts
        // `trial_started` / StartTrial is the only event campaigns bid on -> Neon is revenue truth
        // PostHog stays -> product analytics, not an ad-attribution source
        // FIRST trial->paid only, judged on prior_status='trialing' -> renewals stay out
        // The order and transaction events for one debit both land here -> only the first sees 'trialing'
        // The per-transaction KV mark inside dedupes against the cron settling the same debit
        if (activated[0].prior_status === "trialing") {
          await reportPostHogFirstConversion(env, {
            userId: activated[0].user_id as string,
            transactionId: (pp.merchantOrderId ?? pp.orderId) as string,
            amountPaise: typeof pp.amount === "number" ? pp.amount : null,
            occurredAt: activated[0].updated_at ?? null,
          });
        }
      }

    } else if (
      event === "subscription.redemption.order.failed" ||
      event === "subscription.redemption.transaction.failed"
    ) {
      // Debit failed -> ACKNOWLEDGE ONLY, never touch the row -> retry_count is the dunning ladder's INDEX
      // The cron's reconcile applies the FAILED transition once per order and schedules the next rung off it
      // An increment here advances the index WITHOUT scheduling anything -> a skipped rung and a shortened window
      // It also double-counted -> the webhook adds one, then the cron's reconcile adds one for the same order
      console.log(
        `[payments/webhook] Redemption failed for sub ${merchantSubId}, event: ${event} — cron owns dunning`,
      );

    } else if (
      event === "subscription.revoked" ||
      event === "subscription.cancelled"
    ) {
      // Mandate revoked, by the user in their PSP app or by our own cancel call -> stop future debits
      // Do NOT strip entitlement -> they already paid for the current cycle -> premium runs to current_period_end
      const parked = (await sql`
        UPDATE subscriptions AS s
        SET status        = 'cancelled',
            next_debit_at  = NULL,
            notified_at    = NULL,
            updated_at     = now()
        FROM subscriptions AS prior
        WHERE s.merchant_subscription_id = ${merchantSubId} AND prior.id = s.id
        RETURNING s.user_id, prior.status AS prior_status, s.updated_at
      `) as unknown as {
        user_id: string;
        prior_status: string | null;
        updated_at?: Date | string | null;
      }[];
      if (parked[0]) {
        await reportPostHogSubscriptionCancel(env, {
          userId: parked[0].user_id,
          merchantSubId,
          reason: "webhook_revoked",
          priorStatus: parked[0].prior_status,
          occurredAt: parked[0].updated_at ?? null,
        });
      }

    } else if (event === "subscription.paused") {
      await sql`
        UPDATE subscriptions
        SET status     = 'paused',
            updated_at = now()
        WHERE merchant_subscription_id = ${merchantSubId}
      `;

    } else if (event === "subscription.unpaused") {
      // Resume -> back to active, or trialing while still inside the trial window
      // REARM THE DEBIT CLOCK -> the cron's park path NULLs next_debit_at when it discovers a pause
      // Restoring only `status` left a row neither pass's `next_debit_at <= …` filter can ever select
      // The app then said "Active" forever, nothing billed, and premium died silently at period end
      // COALESCE keeps a webhook-paused row's original schedule; notified_at = NULL makes Pass A re-notify first
      // Scoped to status='paused' -> an unpause must never resurrect a cancelled or expired row
      // Their next_debit_at is gone ON PURPOSE -> restoring it would resume billing someone who stopped
      await sql`
        UPDATE subscriptions
        SET status        = CASE
                              WHEN trial_end IS NOT NULL AND trial_end > now()
                              THEN 'trialing' ELSE 'active'
                            END,
            next_debit_at = COALESCE(next_debit_at, current_period_end),
            notified_at   = NULL,
            updated_at    = now()
        WHERE merchant_subscription_id = ${merchantSubId}
          AND status = 'paused'
      `;

    } else if (
      event === "pg.refund.accepted" ||
      event === "pg.refund.completed" ||
      event === "pg.refund.failed"
    ) {
      // Refunds are operator-initiated for a ₹199 dispute or goodwill -> the ₹2 validation auto-reverses and emits none
      // Do NOT mutate subscription state -> a refund does not end the mandate -> log it for the audit trail only
      console.log(
        `[payments/webhook] Refund event ${event} for sub ${merchantSubId}, ` +
        `order=${pp.merchantOrderId ?? pp.orderId}, state=${pp.state}`,
      );

    } else {
      // Unhandled event -> log and ACK -> a 4xx here makes PhonePe retry something we will never handle
      console.log(`[payments/webhook] Unhandled event: ${event}, sub: ${merchantSubId}`);
    }

    // 5. Mark idempotent
    await env.KV.put(kvKey, "1", { expirationTtl: KV_TXN_TTL });
    return new Response("ok", { status: 200 });

  } catch (err) {
    console.error("[payments/webhook] DB error:", err);
    // 500 so PhonePe RETRIES -> a transient Neon fault on a completed setup used to be acked 200
    // The user had paid, the row never updated, and the event was gone forever with no dead-letter
    // Retrying is safe precisely because the idempotency mark is written ONLY on the success path
    // So a redelivery re-runs from a clean slate and lands exactly one state transition
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

    // Scoped to 'pending' -> both reconcile branches below are no-ops for any other status
    // Calling PhonePe for a lapsed row spent a real API request that could never change an outcome
    // It matters because the paywall reconciles on EVERY open -> that is a lot of pointless calls
    // The guard used to live on the client, keyed off a cached entitlement that was stale exactly when it counted
    // It lives here now -> the ROW decides, never a cache
    if (merchantOrderId && (row.status as string) === "pending") {
      try {
        const orderStatus = await getOrderStatus(env, merchantOrderId);
        phonePeStatus = { state: orderStatus.state, orderId: orderStatus.orderId };

        // PhonePe says COMPLETED while we still say pending -> reconcile -> this MIRRORS the webhook's grant branch
        // trial_end IS NULL -> the first trial; already set -> a repeat subscriber who paid ₹199 at setup
        // The two paths must stay identical -> whichever lands first decides, and they cannot disagree
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
            // Copy the FRESH values back onto `row` -> the response is built from the SELECT taken BEFORE this UPDATE
            // Without it the app was told 'trialing' while trial_end and the period were still pre-reconcile nulls
            // That is the one response that confirms a purchase -> it carried no period at all
            row.status = updated[0].status;
            row.trial_end = updated[0].trial_end;
            row.current_period_end = updated[0].current_period_end;
            row.next_debit_at = updated[0].next_debit_at;
            if (updated[0].status === "active") {
              // The same paid-debit semantics as the webhook path -> idempotent, so both landing is harmless
              await grantReferralReward(sql, updated[0].user_id);
            }
          }
        } else if (
          (orderStatus.state === "FAILED" || orderStatus.state === "EXPIRED") &&
          (row.status as string) === "pending"
        ) {
          // Setup died at the UPI app -> the direct-intent flow's user-cancel lands HERE, with no SDK callback
          // Mirror the failed-setup webhook, RESTORE rule included -> the two paths must never disagree
          // A failed resubscribe over a still-paid period goes back to 'cancelled', the entitlement they owned
          // Only a genuinely period-less or lapsed row becomes 'expired'
          // Without this branch a cancelled intent setup polled its whole budget against a row nothing would flip
          // Without the restore it STRIPPED a live trial
          const failed = await sql<{ status: string }[]>`
            UPDATE subscriptions
            SET status     = CASE WHEN current_period_end IS NOT NULL AND current_period_end > now()
                                  THEN 'cancelled' ELSE 'expired' END,
                updated_at = now()
            WHERE user_id = ${sub}
              AND status  = 'pending'
            RETURNING status
          `;
          row.status = failed[0]?.status ?? "expired";
        }
      } catch (ppErr) {
        // The PhonePe call failed -> non-fatal -> answer from DB state alone rather than failing the poll
        console.warn("[payments/status] PhonePe order status failed:", ppErr);
      }
    }

    // Reconcile the live mandate for revoke/cancel AND pause/unpause -> a user acting in their UPI app fires no webhook
    // So the row goes stale in EITHER direction -> all three heals below are needed
    // CANCELLED/REVOKED while we say live -> flip to 'cancelled', KEEPING current_period_end, which they paid for
    // PAUSED while we say live -> park as 'paused'
    // ACTIVE while we say 'paused' -> the unpause webhook was lost -> restore AND rearm next_debit_at
    // Without that rearm the row is a zombie: "Active" forever, never billed, premium dying at period end
    // Scoped to these statuses -> the pending-setup poll above is not charged a second call, and free users cost nothing
    if (
      merchantSubId &&
      ["trialing", "active", "paused"].includes(row.status as string)
    ) {
      try {
        const subStatus = await getSubscriptionStatus(env, merchantSubId);
        phonePeStatus = phonePeStatus ?? { state: subStatus.state };
        if (subStatus.state === "CANCELLED" || subStatus.state === "REVOKED") {
          const revoked = (await sql`
            UPDATE subscriptions
            SET status        = 'cancelled',
                next_debit_at = NULL,
                notified_at   = NULL,
                updated_at    = now()
            WHERE user_id = ${sub}
              AND status IN ('trialing', 'active', 'paused')
            RETURNING updated_at
          `) as unknown as { updated_at?: Date | string | null }[];
          await reportPostHogSubscriptionCancel(env, {
            userId: sub,
            merchantSubId,
            reason: "revoked_at_phonepe",
            priorStatus: row.status as string,
            occurredAt: revoked[0]?.updated_at ?? null,
          });
          row.status = "cancelled";
          // Mirror the write onto the response row -> otherwise it claims a debit is still coming on a revoked mandate
          row.next_debit_at = null;
        } else if (
          subStatus.state === "PAUSED" &&
          ((row.status as string) === "trialing" || (row.status as string) === "active")
        ) {
          // Lost-pause heal -> the mirror of the cron's parkMandate -> keep the two writes identical
          await sql`
            UPDATE subscriptions
            SET status        = 'paused',
                next_debit_at = NULL,
                notified_at   = NULL,
                updated_at    = now()
            WHERE user_id = ${sub}
              AND status IN ('trialing', 'active')
          `;
          row.status = "paused";
          row.next_debit_at = null;
        } else if (
          subStatus.state === "ACTIVE" &&
          (row.status as string) === "paused"
        ) {
          // Lost-unpause heal -> the same restore AND rearm as the unpaused webhook -> the rearm is not optional
          const restored = await sql<
            { status: string; next_debit_at: unknown }[]
          >`
            UPDATE subscriptions
            SET status        = CASE
                                  WHEN trial_end IS NOT NULL AND trial_end > now()
                                  THEN 'trialing' ELSE 'active'
                                END,
                next_debit_at = COALESCE(next_debit_at, current_period_end),
                notified_at   = NULL,
                updated_at    = now()
            WHERE user_id = ${sub}
              AND status = 'paused'
            RETURNING status, next_debit_at
          `;
          if (restored[0]) {
            row.status = restored[0].status;
            row.next_debit_at = restored[0].next_debit_at;
          }
        }
      } catch (ppErr) {
        console.warn("[payments/status] PhonePe subscription status failed:", ppErr);
      }
    }

    return c.json({
      // The top-level `status` is what the app's purchase poll reads -> never move it into the nested object
      // The nested `subscription` matches SubscriptionModel exactly -> that is what keeps /me and this route in parity
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
// User-initiated cancellation from Manage Subscription -> revoke the mandate so no further debit occurs
// Entitlement is NOT stripped -> premium runs to current_period_end, which they paid for
// The subscription.cancelled webhook finalizes the status -> we write it locally too, so the UI updates at once

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
      // Already terminal -> answer success -> cancelling a cancelled subscription is not an error
      return c.json({ status, cancelled: true });
    }

    if (!merchantSubId) {
      return errorResponse(409, "no_mandate", "Subscription has no PhonePe mandate to revoke");
    }

    // Tolerates the already-inactive case -> a user who revoked in their UPI app is already at the desired end state
    // Only a mandate PhonePe still reports LIVE is a genuine failure worth asking the user to retry
    const revoked = await revokeMandateTolerant(env, merchantSubId);
    if (!revoked) {
      return errorResponse(
        502,
        "phonepe_error",
        "Could not cancel with PhonePe. Please try again.",
      );
    }

    // Stop future debits locally -> keep entitlement to current_period_end -> cancelling is not a refund
    const cancelled = (await sql`
      UPDATE subscriptions
      SET status        = 'cancelled',
          next_debit_at = NULL,
          notified_at   = NULL,
          updated_at    = now()
      WHERE user_id = ${sub}
      RETURNING updated_at
    `) as unknown as { updated_at?: Date | string | null }[];

    await reportPostHogSubscriptionCancel(env, {
      userId: sub,
      merchantSubId,
      reason: "user_cancel",
      priorStatus: status,
      occurredAt: cancelled[0]?.updated_at ?? null,
    });

    return c.json({ status: "cancelled", cancelled: true });
  } catch (err) {
    console.error("[payments/cancel] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /payments/abandon ───────────────────────────────────────────────────
// Called the moment the PhonePe SDK returns without a success -> backed out, interrupted, or an SDK failure
// The claimed 'pending' row is what makes /payments/initiate answer 409 setup_in_progress
// So an explicit release is what lets the very next tap start a fresh setup instead of waiting out the claim window
// Guarded against the one case where "the SDK said cancel" is a LIE -> the stuck-webview class, where it COMPLETED
// So ask PhonePe for the order's live state and REFUSE to expire a completed setup
// The app then gets settled:true and runs its normal status poll, whose reconcile grants exactly like the webhook

export async function handleAbandon(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // The same binding as initiate but its OWN key -> each abandon costs a PhonePe order-status call
  if (!(await allowRequest(env.RL_PAYMENTS, `abandon:${sub}`))) {
    return tooManyRequests("Too many attempts — please wait a minute");
  }

  let body: { merchantOrderId?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }
  const merchantOrderId =
    typeof body.merchantOrderId === "string" ? body.merchantOrderId.trim() : "";
  if (!merchantOrderId) {
    return errorResponse(400, "invalid_body", "merchantOrderId is required");
  }

  const sql = getDb(env);
  try {
    // Scoped to the caller's OWN row AND the exact order the SDK was launched with
    // A late abandon from an old attempt must never release or expire a newer claim -> zero rows there is CORRECT
    const rows = await sql`
      SELECT status, merchant_subscription_id
      FROM subscriptions
      WHERE user_id = ${sub}
        AND merchant_order_id = ${merchantOrderId}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return c.json({ abandoned: false, settled: false });
    }

    const status = rows[0].status as string;
    if (status === "trialing" || status === "active") {
      // The webhook or a status poll already granted -> the SDK's "cancel" was the webview dying AFTER authorization
      return c.json({ abandoned: false, settled: true });
    }
    if (status !== "pending") {
      // Already terminal -> nothing is blocking a retry -> there is no claim left to release
      return c.json({ abandoned: false, settled: false });
    }

    try {
      const order = await getOrderStatus(env, merchantOrderId);
      if (order.state === "COMPLETED") {
        // Authorized at PhonePe, our row simply has not caught up -> DO NOT expire -> tell the app to run its status poll
        return c.json({ abandoned: false, settled: true });
      }
    } catch (ppErr) {
      // We cannot see PhonePe -> refuse to GUESS -> expiring a possibly-completed setup strands a paid mandate
      // Keeping the claim costs the user at most SETUP_CLAIM_WINDOW_MS -> that is the cheaper wrong answer
      console.warn("[payments/abandon] order status failed:", ppErr);
      return c.json({ abandoned: false, settled: false });
    }

    // RESTORE rule, shared with the failed-setup webhook and the status reconcile -> all three must agree
    // Releasing a claim that rode over a still-paid period returns the row to 'cancelled', never 'expired'
    // That is the entitlement the user already owned -> expiring here stripped a live trial on a backed-out resubscribe
    const released = await sql<{ id: string }[]>`
      UPDATE subscriptions
      SET status     = CASE WHEN current_period_end IS NOT NULL AND current_period_end > now()
                            THEN 'cancelled' ELSE 'expired' END,
          updated_at = now()
      WHERE user_id = ${sub}
        AND merchant_order_id = ${merchantOrderId}
        AND status = 'pending'
      RETURNING id
    `;

    // A never-authorized mandate lapses at PhonePe on its own, and the next initiate's supersede path revokes it
    // This only makes sure nothing lingers when the user never retries -> best-effort, off the response path
    // GUARDED ON THE UPDATE ACTUALLY FIRING -> zero rows means the row stopped being 'pending' mid-abandon
    // That is the grant landing between the read above and this write -> revoking there tears down a LIVE, paid mandate
    // The user would keep entitlement we can no longer bill -> the read-time checks cannot close this
    // The whole point is that the state changes underneath them
    const merchantSubId = rows[0].merchant_subscription_id as string | null;
    if (released.length > 0 && merchantSubId) {
      c.executionCtx.waitUntil(
        revokeMandateTolerant(env, merchantSubId).catch((err: unknown) => {
          console.warn(`[payments/abandon] revoke of ${merchantSubId} threw:`, err);
        }),
      );
    }

    console.log(`[payments/abandon] released claim ${merchantOrderId} for user ${sub}`);
    return c.json({ abandoned: true, settled: false });
  } catch (err) {
    console.error("[payments/abandon] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── GET /payments/callback ───────────────────────────────────────────────────────
// Where PhonePe redirects the in-app browser after the mandate -> setupSubscription's redirectUrl points here
// Authoritative state comes from the S2S webhook and the app's status poll -> this page decides NOTHING
// It exists only so the redirect does not 404, and to nudge the user back to the app

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
