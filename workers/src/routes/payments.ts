/**
 * Every response shape here is parsed by the shipped Flutter models -> a renamed key breaks installs that never update
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { sanitizeAnalyticsContext } from "../lib/analytics-context.js";
import { requestSignal } from "../lib/request-signal.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { getDb, toDate } from "../lib/db.js";
import { grantReferralReward } from "../lib/referral.js";
import { reportPostHogFirstConversion, reportPostHogSubscriptionCancel } from "../lib/posthog.js";
import { CANCEL_OFFER, OFFER_PRICE_PAISE, STANDARD_PRICE_PAISE, WINBACK_OFFER } from "../lib/pricing.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
import { rearmUnpausedSubscription } from "../lib/subscription-rearm.js";
import {
  addOneMonth,
  cancelOfferEligible,
  grantCompletedSetup,
  healSettledDebit,
  honourLateOfferApproval,
  noteRevokeRetry,
  parkSubscription,
  releaseClaim,
  type SetupGrant,
  TRIAL_MS,
  winbackOfferEligible,
} from "../lib/subscription-state.js";
import {
  setupSubscription,
  setupSubscriptionIntent,
  revokeMandateTolerant,
  verifyCallbackAuth,
  getSubscriptionStatus,
  getOrderStatus,
  buildMerchantSubscriptionId,
  buildMerchantOrderId,
  merchantKeys,
  merchantOf,
  setupMerchant,
  setupMerchantMode,
  type Merchant,
  type PhonePeWebhookPayload,
  merchantSubscriptionIdOf,
  phonePeSubscriptionIdOf,
} from "../lib/phonepe.js";

const KV_TXN_TTL = 30 * 24 * 60 * 60; // 30 days — covers PhonePe's retry window

/** Mandate state changes carry no order id, only the mandate's ids, state and pause window (docs/phonepe-webhook.md). */
const STATE_EVENTS = new Set([
  "subscription.paused",
  "subscription.unpaused",
  "subscription.revoked",
  "subscription.cancelled",
]);

/**
 * Empty = never deduped. An unpause carries null pause dates, so any key would drop every later unpause of the
 * same mandate inside the TTL -> it relies on the rearm's `status = 'paused'` scope instead
 */
function stateEventDedupeId(event: string, pp: PhonePeWebhookPayload["payload"]): string {
  const merchantSubId = merchantSubscriptionIdOf(pp);
  if (!merchantSubId || event === "subscription.unpaused") return "";
  return `${merchantSubId}:${pp.state ?? ""}:${pp.pauseStartDate ?? ""}`;
}

/**
 * PAIRED with the client's silent retries -> their delays SUM to this window
 * Change either side and re-check that sum(retry delays) >= this window
 */
const SETUP_CLAIM_WINDOW_MS = 4_000;

interface PriorSubscription {
  trial_end: unknown;
  status: string;
  merchant_subscription_id: string | null;
  superseded_mandate_id: string | null;
  superseded_price_paise: number | string | null;
  price_paise: number | string;
  offer_mandate_id: string | null;
  offer_switch?: boolean | null;
  redemption_order_id: string | null;
  current_period_end: unknown;
  updated_at: unknown;
  offer_eligible: boolean | null;
  winback_eligible: boolean | null;
}

/**
 * Why a claim was refused. The reasons MUST stay distinguishable all the way out to the client.
 */
type ClaimConflict = "active_subscription" | "setup_in_flight" | "offer_unavailable";

type ClaimResult =
  | {
      conflict: ClaimConflict;
      supersededMandateId?: undefined;
      trialEligible?: undefined;
      staleOfferMandateId?: undefined;
    }
  | {
      conflict: false;
      supersededMandateId: string | null;
      trialEligible: boolean;
      staleOfferMandateId: string | null;
    };

export async function handleInitiate(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // Every call creates a REAL PhonePe mandate-setup order -> keyed by user, so one account cannot burn the API quota
  if (!(await allowRequest(env.RL_PAYMENTS, `initiate:${sub}`))) {
    console.warn(`[payments/initiate] rate limited user ${sub}`);
    return tooManyRequests("Too many subscription attempts — please wait a minute");
  }

  let body: { plan?: string; targetApp?: string; mode?: string; context?: unknown; offer?: unknown };
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
  // An unknown offer is refused, never read as a plain checkout at the full price
  const offer = body.offer === CANCEL_OFFER || body.offer === WINBACK_OFFER ? body.offer : null;
  if (body.offer !== undefined && body.offer !== null && offer === null) {
    return errorResponse(400, "invalid_offer", `offer must be '${CANCEL_OFFER}' or '${WINBACK_OFFER}'`);
  }
  // Only the switch parks a live plan behind a ₹2 check; a winback is an ordinary paid re-setup at ₹99
  const cancelOffer = offer === CANCEL_OFFER;
  const pricePaise = offer ? OFFER_PRICE_PAISE : STANDARD_PRICE_PAISE;

  // Shape check only -> PhonePe validates the package itself -> do not maintain an allow-list here
  const targetApp =
    typeof body.targetApp === "string" && /^[a-zA-Z][a-zA-Z0-9._]{2,100}$/.test(body.targetApp)
      ? body.targetApp
      : null;

  const qrMode = body.mode === "qr" && targetApp !== null;
  const recordedTargetApp = qrMode ? "qr" : (targetApp ?? "phonepe_page");
  // Analytics only (PostHog's warehouse reads it) -> junk is dropped, never a reason to refuse a checkout
  const sent = sanitizeAnalyticsContext(body.context);
  const signal = requestSignal(c.req.raw);
  const checkoutContext = sent || Object.keys(signal).length ? { ...(sent ?? {}), ...signal } : null;

  const sql = getDb(env);
  const tails: Promise<unknown>[] = [];
  try {
    // PhonePe reads cannot sit under the row lock -> this unlocked read only decides whether to ask PhonePe first;
    // the claim below re-reads and re-decides under the lock
    let seen = await readClaimRow(sql, sub);

    if (cancelOffer) {
      if (claimInFlight(seen)) return setupInProgress();
      // Their own earlier switch attempt never reported back (app left inside the UPI app) -> hand the ₹199 back
      // first, so a second try is judged on the plan they still have, not refused as ineligible
      if (seen?.status === "pending" && seen.offer_switch === true) {
        await releaseClaim(sql, sql`s.user_id = ${sub} AND s.offer_switch`);
        seen = await readClaimRow(sql, sub);
      }
      if (seen?.offer_eligible !== true) return offerUnavailable();
      const gate = await offerMandateGate(env, sql, sub, seen.merchant_subscription_id as string);
      if (gate === "error") return errorResponse(502, "phonepe_error", "PhonePe gateway error");
      if (gate === "unavailable") return offerUnavailable();
    } else {
      if (offer) {
        if (claimInFlight(seen)) return setupInProgress();
        if (seen?.winback_eligible !== true) return offerUnavailable();
      }
      // A debit that settled while the row was out of the cron's reach looks like "no premium" -> the user taps
      // Subscribe again, and a claim would move the row to 'pending' past every heal -> heal it and answer instead
      if (
        seen?.redemption_order_id &&
        !hasLiveSubscription(seen) &&
        (await healBeforeClaim(c, sql, sub, seen, tails))
      ) {
        return errorResponse(409, "already_subscribed", "You already have an active subscription");
      }
    }

    // Build the ids up front -> the claim below writes them BEFORE PhonePe is called
    // That is what lets a concurrent request see a setup is already underway
    const merchant = await chooseSetupMerchant(env, sql, sub);
    const merchantSubscriptionId = buildMerchantSubscriptionId(sub, merchant);
    const merchantOrderId = buildMerchantOrderId(sub, "S", merchant);

    // The lock is on the USERS row, NOT subscriptions -> a first-time subscriber has no subscriptions row to lock
    // FOR UPDATE there would lock nothing and the exact race would slip through
    // Claiming BEFORE the PhonePe call is what makes the in-flight check work at all
    // The marker must be visible to the second request while the first is still waiting on PhonePe
    const claim = (await sql.begin(async (tx) => {
      await tx`SELECT 1 FROM users WHERE id = ${sub} FOR UPDATE`;

      const existing = await readClaimRow(tx as unknown as ReturnType<typeof getDb>, sub);

      const priorPeriodEnd = toDate(existing?.current_period_end);
      const hasLivePeriod = priorPeriodEnd !== null && priorPeriodEnd.getTime() > Date.now();
      // A pending row touched moments ago means another request is MID-SETUP -> refuse, never authorize a second mandate
      // The caller retries and gets the settled state -> refusing costs a retry, authorizing costs a stranded mandate
      if (claimInFlight(existing)) return { conflict: "setup_in_flight" } as ClaimResult;

      if (offer) {
        // Eligibility re-checked under the lock -> neither the client nor the unlocked read is trusted
        const eligible = cancelOffer ? existing?.offer_eligible : existing?.winback_eligible;
        if (eligible !== true) return { conflict: "offer_unavailable" } as ClaimResult;
      } else if (
        existing &&
        (existing.status === "trialing" || existing.status === "active") &&
        hasLivePeriod
      ) {
        return { conflict: "active_subscription" } as ClaimResult;
      }

      // Whatever mandate this row pointed at is about to become unreachable -> capture it UNDER the lock
      // Otherwise a losing concurrent request revokes the WINNER's mandate, using an id it read before the race
      // A parked id already on the row rides along -> a second re-subscribe over an unapproved one must not lose it
      const keepAlive =
        existing !== null &&
        existing.merchant_subscription_id !== null &&
        (existing.status === "trialing" || existing.status === "active" || existing.status === "paused");
      const parkedMandateId = keepAlive
        ? existing.merchant_subscription_id
        : (existing?.superseded_mandate_id ?? null);
      const parkedPricePaise =
        parkedMandateId === null
          ? null
          : keepAlive
            ? Number(existing.price_paise)
            : Number(existing?.superseded_price_paise ?? STANDARD_PRICE_PAISE);
      const superseded =
        existing?.merchant_subscription_id && (existing.status === "pending" || existing.status === "expired")
          ? existing.merchant_subscription_id
          : null;

      // price_paise is written on EVERY claim -> a lapsed ₹99 subscriber who re-subscribes is back on ₹199
      await tx`
        INSERT INTO subscriptions (
          user_id, status, plan, merchant_subscription_id, merchant_order_id, upi_target_app,
          superseded_mandate_id, superseded_price_paise, price_paise, offer_switch, checkout_context
        )
        VALUES (
          ${sub}, 'pending', ${plan}, ${merchantSubscriptionId}, ${merchantOrderId},
          ${recordedTargetApp}, ${parkedMandateId}, ${parkedPricePaise}, ${pricePaise}, ${cancelOffer},
          ${checkoutContext ? JSON.stringify(checkoutContext) : null}::text::jsonb
        )
        ON CONFLICT (user_id)
        DO UPDATE SET
          status                   = 'pending',
          plan                     = EXCLUDED.plan,
          merchant_subscription_id = EXCLUDED.merchant_subscription_id,
          merchant_order_id        = EXCLUDED.merchant_order_id,
          upi_target_app           = EXCLUDED.upi_target_app,
          superseded_mandate_id    = EXCLUDED.superseded_mandate_id,
          superseded_price_paise   = EXCLUDED.superseded_price_paise,
          price_paise              = EXCLUDED.price_paise,
          offer_switch             = EXCLUDED.offer_switch,
          offer_mandate_id         = NULL,
          checkout_context         = EXCLUDED.checkout_context,
          phonepe_order_id         = NULL,
          updated_at               = now()
      `;
      if (keepAlive) {
        console.log(
          `[payments/initiate] parked live mandate ${existing.merchant_subscription_id} for user ${sub} — ` +
            `revoked only once the new setup is approved${cancelOffer ? " (cancel_99 switch)" : ""}`,
        );
      }

      return {
        conflict: false,
        supersededMandateId: superseded,
        // The switch is a ₹2 PENNY_DROP whatever trial_end says, a winback a paid setup -> neither starts a trial
        trialEligible: offer === null && (existing === null || existing.trial_end === null),
        staleOfferMandateId: existing?.offer_mandate_id ?? null,
      } as ClaimResult;
    })) as unknown as ClaimResult;

    if (claim.conflict === "setup_in_flight") return setupInProgress();
    if (claim.conflict === "offer_unavailable") return offerUnavailable();
    if (claim.conflict) {
      return errorResponse(409, "already_subscribed", "You already have an active subscription");
    }

    const { supersededMandateId, trialEligible, staleOfferMandateId } = claim;
    // A released switch's ₹99 was still watched for a late approval -> this fresh attempt replaces it
    if (staleOfferMandateId && staleOfferMandateId !== merchantSubscriptionId) {
      revokeInBackground(c, staleOfferMandateId, "payments/initiate");
    }
    const upfrontAmountPaise = trialEligible || cancelOffer ? undefined : pricePaise;
    const setupAmountPaise = upfrontAmountPaise ?? 200;
    const offerFields = offer ? { offer, pricePaise } : {};

    // Attach PhonePe's order id to the row already claimed above, SCOPED to the claimed merchant_order_id
    // A later initiate may have superseded this claim while PhonePe answered -> this must not stamp the newer mandate
    // Zero rows updated is the CORRECT outcome there -> the newer request owns the row
    // `upiTargetApp` is re-stamped here because the flow can CHANGE after the claim: an intent setup
    // that fails falls back to the hosted page, and the row must say which one actually ran.
    const attachPhonePeOrder = async (phonepeOrderId: string, upiTargetApp: string) => {
      await sql`
        UPDATE subscriptions
        SET phonepe_order_id = ${phonepeOrderId},
            upi_target_app   = ${upiTargetApp},
            updated_at       = now()
        WHERE user_id = ${sub}
          AND merchant_order_id = ${merchantOrderId}
      `;
    };

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
              console.error(`[payments/initiate] Revoke of superseded mandate ${staleMandateId} threw:`, err);
            }),
        );
      }
    };

    // Accepted edge: a 200 without an intentUrl leaves an order at PhonePe under this merchantOrderId
    // The sdk/order fallback may then 409/400 -> the user's next tap supersedes it cleanly
    if (targetApp) {
      try {
        const intent = await setupSubscriptionIntent(env, {
          merchantOrderId,
          merchantSubscriptionId,
          targetApp,
          upfrontAmountPaise,
          maxAmountPaise: pricePaise,
        });
        await attachPhonePeOrder(intent.orderId, recordedTargetApp);
        revokeSuperseded();
        console.log(
          `[payments/initiate] env=${env.PHONEPE_ENV} merchant=${merchant} flow=${qrMode ? "qr" : "intent"} ` +
            `target=${recordedTargetApp} orderId=${intent.orderId} state=${intent.state} ` +
            `trialEligible=${trialEligible} price=${pricePaise}`,
        );
        return c.json({
          flow: qrMode ? "qr" : "intent",
          merchantSubscriptionId,
          merchantOrderId,
          orderId: intent.orderId,
          state: intent.state,
          intentUrl: intent.intentUrl,
          trialEligible,
          amountPaise: setupAmountPaise,
          ...offerFields,
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

    let ppResult;
    try {
      ppResult = await setupSubscription(env, {
        userId: sub,
        merchantSubscriptionId,
        merchantOrderId,
        redirectUrl,
        upfrontAmountPaise,
        maxAmountPaise: pricePaise,
      });
    } catch (ppErr) {
      console.error("[payments/initiate] PhonePe error:", ppErr);
      // No order reached the user -> an offer claim left pending would read as ineligible to their "Try again"
      if (cancelOffer) {
        await releaseClaim(sql, sql`s.user_id = ${sub} AND s.merchant_order_id = ${merchantOrderId}`);
      }
      return errorResponse(502, "phonepe_error", "PhonePe gateway error");
    }

    // They only blow up inside the SDK -> log their SHAPE, never their value, so the next failed tap names the culprit
    // The SDK must init with the merchant that OWNS this order -> never the unprefixed PHONEPE_MERCHANT_ID by habit
    const sdkMerchantId = merchantKeys(env, merchant).merchantId;
    console.log(
      `[payments/initiate] env=${env.PHONEPE_ENV} merchant=${merchant} ` +
        `merchantIdLen=${sdkMerchantId.length} ` +
        `merchantIdPrefix=${sdkMerchantId.slice(0, 4)} ` +
        `tokenLen=${ppResult.token?.length ?? 0} ` +
        `orderId=${ppResult.orderId} state=${ppResult.state} ` +
        `trialEligible=${trialEligible} price=${pricePaise}`,
    );

    await attachPhonePeOrder(ppResult.orderId, "phonepe_page");
    revokeSuperseded();

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
      merchantId: sdkMerchantId,
      // Trimmed for the same reason. isProduction() trims before choosing the
      // host, so an untrimmed value here would route the Worker to the RIGHT
      // host while the app inits the SDK with "PRODUCTION\n" — the two would
      // silently disagree. The client rejects an empty/missing value outright.
      environment: env.PHONEPE_ENV.trim(),
      trialEligible,
      amountPaise: setupAmountPaise,
      ...offerFields,
    });
  } catch (err) {
    console.error("[payments/initiate] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(Promise.allSettled(tails).then(() => sql.end()));
  }
}

/** The claim's view of the user's ONE row, with both offers' eligibility evaluated in the same read. */
async function readClaimRow(sql: ReturnType<typeof getDb>, sub: string): Promise<PriorSubscription | null> {
  const rows = (await sql`
    SELECT s.trial_end, s.status, s.merchant_subscription_id, s.superseded_mandate_id, s.superseded_price_paise,
           s.price_paise, s.offer_mandate_id, s.offer_switch, s.redemption_order_id, s.current_period_end, s.updated_at,
           ${winbackOfferEligible(sql)} AS winback_eligible, ${cancelOfferEligible(sql)} AS offer_eligible
    FROM subscriptions AS s
    WHERE s.user_id = ${sub}
    LIMIT 1
  `) as unknown as PriorSubscription[];
  return rows[0] ?? null;
}

function claimInFlight(row: PriorSubscription | null): boolean {
  const claimedAt = toDate(row?.updated_at);
  return (
    row?.status === "pending" &&
    claimedAt !== null &&
    Date.now() - claimedAt.getTime() < SETUP_CLAIM_WINDOW_MS
  );
}

function setupInProgress(): Response {
  return errorResponse(
    409,
    "setup_in_progress",
    "A payment setup is already in progress. Please wait a few seconds and try again.",
  );
}

function hasLiveSubscription(row: PriorSubscription): boolean {
  const periodEnd = toDate(row.current_period_end);
  return (
    (row.status === "trialing" || row.status === "active") &&
    periodEnd !== null &&
    periodEnd.getTime() > Date.now()
  );
}

/**
 * True = the row's open redemption order already took the money, so the tap must not claim. The heal grants a
 * never-converted row; a trialing/active one is left to the cron's own settle, which still selects it
 */
async function healBeforeClaim(
  c: Context<{ Bindings: Env }>,
  sql: ReturnType<typeof getDb>,
  sub: string,
  row: PriorSubscription,
  tails: Promise<unknown>[],
): Promise<boolean> {
  const orderId = row.redemption_order_id as string;
  try {
    const order = await getOrderStatus(c.env, orderId);
    if (order.state !== "COMPLETED") return false;
    const healed = await healSettledDebit(c.env, sql, sql`s.user_id = ${sub}`, orderId);
    if (healed?.prior_mandate_id && healed.prior_mandate_id !== healed.merchant_subscription_id) {
      tails.push(revokeTolerantly(c.env, healed.prior_mandate_id, "payments/initiate"));
    }
    return healed !== null || row.status === "trialing" || row.status === "active";
  } catch (err) {
    // We cannot see PhonePe -> claim as before; the hourly heal still finds a settled order
    console.warn(`[payments/initiate] order ${orderId} status before claim failed:`, err);
    return false;
  }
}

/**
 * The offer only ever switches AWAY from a mandate PhonePe still bills. Anything but ACTIVE syncs the row with the
 * status route's own writes and refuses; a failed read changes nothing and the user can retry
 */
async function offerMandateGate(
  env: Env,
  sql: ReturnType<typeof getDb>,
  sub: string,
  mandateId: string,
): Promise<"ok" | "unavailable" | "error"> {
  let state: string;
  try {
    state = (await getSubscriptionStatus(env, mandateId)).state;
  } catch (err) {
    console.warn(`[payments/initiate] offer: mandate ${mandateId} status failed:`, err);
    return "error";
  }
  if (state === "ACTIVE") return "ok";
  if (state === "CANCELLED" || state === "REVOKED") {
    await parkSubscription(env, sql, sql`s.user_id = ${sub}`, "cancelled", "revoked_at_phonepe");
  } else if (state === "PAUSED") {
    await parkSubscription(env, sql, sql`s.user_id = ${sub}`, "paused");
  }
  console.log(`[payments/initiate] offer refused for user ${sub}: live mandate ${mandateId} is ${state}`);
  return "unavailable";
}

/** The release CASE in JS: the status a pending switch's parked mandate had before the claim. */
function switchParkedStatus(row: { trial_end?: unknown; current_period_end?: unknown }): string {
  const trialEnd = toDate(row.trial_end);
  const periodEnd = toDate(row.current_period_end);
  return trialEnd !== null && periodEnd !== null && periodEnd.getTime() > trialEnd.getTime()
    ? "active"
    : "trialing";
}

function offerUnavailable(): Response {
  return errorResponse(409, "offer_unavailable", "This offer is not available");
}

export async function handleWebhook(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const authHeader = c.req.header("Authorization") ?? "";
  // Each merchant's dashboard webhook carries its own SHA pair -> either one authenticates a delivery
  const pairs = (
    [
      ["legacy", env.PHONEPE_WEBHOOK_USERNAME, env.PHONEPE_WEBHOOK_PASSWORD],
      ["hsr", env.PHONEPE_HSR_WEBHOOK_USERNAME, env.PHONEPE_HSR_WEBHOOK_PASSWORD],
    ] as const
  ).filter(([, username, password]) => !!username && !!password);

  if (pairs.length === 0) {
    // Missing secrets = misconfiguration; fail closed
    console.error("[payments/webhook] no PHONEPE_WEBHOOK_* or PHONEPE_HSR_WEBHOOK_* pair set");
    return new Response("ok", { status: 200 }); // ack to stop retries; alert on logs
  }

  // Read the body ONCE, before the auth check, so a rejected delivery can still
  // be described in the logs (see below). c.req.text() cannot be called twice.
  const rawBody = await c.req.text();

  const authPairs: Merchant[] = [];
  for (const [merchant, username, password] of pairs) {
    if (await verifyCallbackAuth(authHeader, username ?? "", password ?? "")) authPairs.push(merchant);
  }
  if (authPairs.length === 0) {
    // LOUD on purpose -> a silent 401 made two very different situations look identical from outside
    // Log SHAPE, never content -> whether a header arrived, its length, whether it looks like 64-char lowercase hex
    // Never the header itself and never the configured credentials -> a log is not a place to leak either
    const looksLikeSha256Hex = /^[0-9a-f]{64}$/.test(authHeader.trim());
    let eventPeek = "<unparseable>";
    try {
      const peek = JSON.parse(rawBody) as PhonePeWebhookPayload;
      eventPeek = `${peek.event ?? peek.type ?? "?"} sub=${merchantSubscriptionIdOf(peek.payload) ?? "?"}`;
    } catch {
      // leave the placeholder
    }
    console.error(
      `[payments/webhook] REJECTED a delivery on auth. ` +
        `authHeader present=${authHeader.length > 0} len=${authHeader.length} ` +
        `sha256HexShaped=${looksLikeSha256Hex} event=${eventPeek}. ` +
        `If this is PhonePe, the dashboard's webhook username/password match neither ` +
        `PHONEPE_WEBHOOK_* (legacy) nor PHONEPE_HSR_WEBHOOK_* (hsr) on this Worker.`,
    );
    return errorResponse(401, "invalid_signature", "Webhook authorization failed");
  }

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
  const stateEvent = STATE_EVENTS.has(event);
  const dedupeKey = stateEvent ? stateEventDedupeId(event, pp) : (pp.orderId ?? pp.merchantOrderId ?? "");
  if (!dedupeKey && !stateEvent) {
    console.error("[payments/webhook] Missing orderId/merchantOrderId, event:", event);
    return new Response("ok", { status: 200 });
  }

  const kvKey = dedupeKey ? `txn:${event}:${dedupeKey}` : null;
  const alreadyProcessed = kvKey ? await env.KV.get(kvKey) : null;
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

  // The id's marker names the merchant; an ORDER event also names it in payload.merchantId (state events do not)
  // Only a PROVEN contradiction is refused -> an unfamiliar merchantId format must never drop a real grant
  const idMerchant = merchantOf(merchantSubId);
  const otherMerchant: Merchant = idMerchant === "hsr" ? "legacy" : "hsr";
  const payloadMerchantId = typeof pp.merchantId === "string" ? pp.merchantId.trim() : "";
  const orderMerchant = pp.merchantOrderId?.startsWith("DKS_") ? merchantOf(pp.merchantOrderId) : idMerchant;
  if (
    orderMerchant !== idMerchant ||
    (payloadMerchantId !== "" && payloadMerchantId === configuredMerchantId(env, otherMerchant))
  ) {
    console.error(
      `[payments/webhook] MERCHANT MISMATCH — ${event} for ${idMerchant} id ${merchantSubId} ` +
        `(order ${pp.merchantOrderId ?? "?"}) names merchant ${payloadMerchantId || "?"}; ` +
        `not processing and not marking`,
    );
    return new Response("ok", { status: 200 });
  }
  if (payloadMerchantId !== "" && payloadMerchantId !== configuredMerchantId(env, idMerchant)) {
    console.warn(
      `[payments/webhook] ${event} for ${idMerchant} id ${merchantSubId} carries an unrecognised ` +
        `merchantId ${payloadMerchantId} — processed by the id`,
    );
  }
  if (!authPairs.includes(idMerchant)) {
    console.warn(
      `[payments/webhook] ${event} for ${idMerchant} id ${merchantSubId} authenticated with the ` +
        `${authPairs.join("/")} pair — processed by the id`,
    );
  }

  const sql = getDb(env);
  const tails: Promise<unknown>[] = [];
  try {
    if (
      event === "checkout.order.completed" ||
      event === "checkout.setup.order.completed" ||
      event === "subscription.setup.order.completed"
    ) {
      // COALESCE on phonepe_subscription_id -> a payload that omits subscriptionId must never blank an id we hold
      const phonepeSubId = phonePeSubscriptionIdOf(pp);
      const granted = await grantCompletedSetup(
        sql,
        sql`s.merchant_subscription_id = ${merchantSubId}`,
        phonepeSubId,
      );

      if (granted) {
        console.log(
          `[payments/webhook] Setup completed for sub ${merchantSubId} → ${granted.status}` +
            `${granted.kind === "switch" ? " (cancel_99 switch)" : ""}, amount=${pp.amount ?? "?"}`,
        );
        tails.push(retireStaleMandate(env, sql, granted, "payments/webhook"));
        if (granted.kind === "grant" && granted.status === "active") {
          // A repeat subscriber paid ₹199 at setup -> that IS a paid debit -> the referral reward applies here too
          await grantReferralReward(sql, granted.user_id);
          // Audit -> a repeat subscriber's setup order must carry the REAL charge
          // amount=200 here means a stale PENNY_DROP order completed for a trial-consumed user
          if (typeof pp.amount === "number" && pp.amount < Number(granted.price_paise)) {
            console.warn(
              `[payments/webhook] Trial-consumed user activated via setup order of only ${pp.amount} paise (sub ${merchantSubId})`,
            );
          }
        }
      } else if (await settleLateOffer(env, sql, merchantSubId, phonepeSubId, tails)) {
        // A released or cancelled switch's ₹99 -> honoured or revoked, never resurrected into a paid month
      } else {
        // The user PAID -> a ₹199 TRANSACTION, or an authorized trial mandate -> refusing the grant eats real money
        // So resurrect, scoped to the EXACT ids of THIS event and only those two post-abandon statuses
        // An OLD dunning-expired or user-cancelled subscription can never match -> fresh setups carry fresh ids
        const trialEnd = new Date(Date.now() + TRIAL_MS);
        const paidEnd = addOneMonth(new Date());
        const resurrected = await sql<{ user_id: string; status: string; stale_mandate_id: string | null }[]>`
          UPDATE subscriptions AS s
          SET status                   = CASE WHEN s.trial_end IS NULL THEN 'trialing' ELSE 'active' END,
              phonepe_subscription_id  = COALESCE(${phonepeSubId}, s.phonepe_subscription_id),
              trial_end                = COALESCE(s.trial_end, ${trialEnd.toISOString()}),
              current_period_end       = CASE WHEN s.trial_end IS NULL
                                              THEN ${trialEnd.toISOString()}::timestamptz
                                              ELSE ${paidEnd.toISOString()}::timestamptz END,
              next_debit_at            = CASE WHEN s.trial_end IS NULL
                                              THEN ${trialEnd.toISOString()}::timestamptz
                                              ELSE ${paidEnd.toISOString()}::timestamptz END,
              notified_at              = NULL,
              retry_count              = 0,
              first_debit_at           = CASE WHEN s.trial_end IS NULL THEN s.first_debit_at
                                              ELSE COALESCE(s.first_debit_at, now()) END,
              debit_count              = CASE WHEN s.trial_end IS NULL THEN s.debit_count ELSE s.debit_count + 1 END,
              paid_paise               = CASE WHEN s.trial_end IS NULL THEN s.paid_paise
                                              ELSE s.paid_paise + s.price_paise END,
              superseded_mandate_id    = NULL,
              superseded_price_paise   = NULL,
              updated_at               = now()
          FROM subscriptions AS prior
          WHERE s.merchant_subscription_id = ${merchantSubId}
            AND s.merchant_order_id = ${pp.merchantOrderId ?? ""}
            AND s.status IN ('expired', 'cancelled')
            AND NOT s.offer_switch
            AND prior.id = s.id
          RETURNING s.user_id, s.status, prior.superseded_mandate_id AS stale_mandate_id
        `;
        const row = resurrected[0];
        if (row) {
          console.log(
            `[payments/webhook] Setup completed for sub ${merchantSubId} — ` +
              `RESURRECTED an abandon-expired claim (approval raced the auto-cancel); grant applied`,
          );
          if (row.stale_mandate_id && row.stale_mandate_id !== merchantSubId) {
            tails.push(revokeTolerantly(env, row.stale_mandate_id, "payments/release"));
          }
          if (row.status === "active") await grantReferralReward(sql, row.user_id);
        } else {
          // Both are state no-ops but they are NOT the same operationally -> the log must say which
          // The ::text casts are LOAD-BEARING -> `fetch_types:false` gives Postgres no type context for a bare parameter
          // A parameter appearing only inside `${x} IS NOT NULL` then fails the whole statement on type inference
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
        }
      }
    } else if (
      event === "checkout.order.failed" ||
      event === "checkout.setup.order.failed" ||
      event === "subscription.setup.order.failed"
    ) {
      await releaseClaim(sql, sql`s.merchant_subscription_id = ${merchantSubId}`);
    } else if (
      (event === "subscription.redemption.order.completed" ||
        event === "subscription.redemption.transaction.completed") &&
      typeof pp.state === "string" &&
      pp.state !== "COMPLETED"
    ) {
      console.log(
        `[payments/webhook] ${event} for sub ${merchantSubId} carries state=${pp.state} — not a settled order, no grant`,
      );
    } else if (
      event === "subscription.redemption.order.completed" ||
      event === "subscription.redemption.transaction.completed"
    ) {
      // The self-join FROM reads the row's PRE-UPDATE snapshot -> the only place the prior status still exists
      // 'trialing' at settle = the FIRST trial->paid conversion; 'active' = a renewal
      // Every SET and WHERE column is qualified -> both aliases expose the same column names
      const nextEnd = addOneMonth(new Date());
      const phonepeSubId = phonePeSubscriptionIdOf(pp);
      const settledOrderId = pp.merchantOrderId ?? null;

      const activated = await sql<
        {
          user_id: string;
          prior_status: string;
          updated_at?: Date | string | null;
          upi_target_app?: string | null;
          prior_mandate_id?: string | null;
          price_paise: number | string;
        }[]
      >`
        UPDATE subscriptions AS s
        SET status                  = 'active',
            merchant_subscription_id = ${merchantSubId},
            -- The debited mandate's own price: a parked one made live again brings its price back with it
            price_paise             = CASE WHEN s.merchant_subscription_id = ${merchantSubId} THEN s.price_paise
                                           ELSE COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE}) END,
            superseded_mandate_id   = NULL,
            superseded_price_paise  = NULL,
            offer_switch            = false,
            phonepe_subscription_id = COALESCE(${phonepeSubId}, s.phonepe_subscription_id),
            current_period_end      = ${nextEnd.toISOString()},
            next_debit_at           = ${nextEnd.toISOString()},
            notified_at             = NULL,
            redemption_order_id     = NULL,
            retry_count             = 0,
            first_debit_at          = COALESCE(s.first_debit_at, now()),
            debit_count             = s.debit_count + 1,
            paid_paise              = s.paid_paise + CASE WHEN s.merchant_subscription_id = ${merchantSubId}
                                                          THEN s.price_paise
                                                          ELSE COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE}) END,
            updated_at              = now()
        FROM subscriptions AS prior
        WHERE (s.merchant_subscription_id = ${merchantSubId} OR s.superseded_mandate_id = ${merchantSubId})
          AND prior.id = s.id
          -- One settle per order: the cron's settle clears redemption_order_id and moves next_debit_at a month out,
          -- so this matches only an order still in flight, or a debit still owed whose order was recycled
          AND (s.redemption_order_id = ${settledOrderId}
               OR (s.redemption_order_id IS NULL
                   AND (s.next_debit_at IS NULL OR s.next_debit_at <= now() + interval '1 day')))
        RETURNING s.user_id, prior.status AS prior_status, s.updated_at, s.upi_target_app,
                  prior.merchant_subscription_id AS prior_mandate_id, s.price_paise
      `;

      console.log(
        activated.length > 0
          ? `[payments/webhook] Active for sub ${merchantSubId}, period_end=${nextEnd.toISOString()}`
          : `[payments/webhook] Order ${settledOrderId ?? "?"} for sub ${merchantSubId} already settled — no second grant`,
      );

      // Referral reward -> this user just made a paid debit -> only the FIRST ever grants, via the status<>'rewarded' guard
      if (activated.length > 0) {
        const priorMandateId = activated[0].prior_mandate_id ?? null;
        if (priorMandateId && priorMandateId !== merchantSubId) {
          revokeInBackground(c, priorMandateId, "payments/webhook");
        }
        await grantReferralReward(sql, activated[0].user_id);
        // FIRST trial->paid only, judged on prior_status='trialing' -> renewals stay out
        // The order and transaction events for one debit both land here -> only the first sees 'trialing'
        // The per-transaction KV mark inside dedupes against the cron settling the same debit
        // After the response -> an analytics round-trip must never hold PhonePe's acknowledgement back
        if (activated[0].prior_status === "trialing") {
          c.executionCtx.waitUntil(
            reportPostHogFirstConversion(env, {
              userId: activated[0].user_id as string,
              transactionId: (pp.merchantOrderId ?? pp.orderId) as string,
              amountPaise: typeof pp.amount === "number" ? pp.amount : Number(activated[0].price_paise),
              occurredAt: activated[0].updated_at ?? null,
              targetApp: activated[0].upi_target_app ?? null,
              merchantSubId,
            }),
          );
        }
      }
    } else if (
      event === "subscription.redemption.order.failed" ||
      event === "subscription.redemption.transaction.failed"
    ) {
      console.log(
        `[payments/webhook] Redemption failed for sub ${merchantSubId}, event: ${event} — cron owns dunning`,
      );
    } else if (event === "subscription.revoked" || event === "subscription.cancelled") {
      // A pending claim's UNAPPROVED id dying (PhonePe expiring the setup, or our own revoke racing the release) is a
      // failed setup, not a cancel: cancelling it would strand the parked mandate, never billed nor revoked again
      const released = await releaseClaim(
        sql,
        sql`s.merchant_subscription_id = ${merchantSubId} AND s.superseded_mandate_id IS NOT NULL`,
      );
      const parked = released.length
        ? []
        : ((await sql`
            UPDATE subscriptions AS s
            SET status        = 'cancelled',
                next_debit_at  = NULL,
                notified_at    = NULL,
                updated_at     = now()
            FROM subscriptions AS prior
            WHERE s.merchant_subscription_id = ${merchantSubId} AND prior.id = s.id
            RETURNING s.user_id, prior.status AS prior_status, s.updated_at, s.price_paise
          `) as unknown as {
            user_id: string;
            prior_status: string | null;
            updated_at?: Date | string | null;
            price_paise?: number | string | null;
          }[]);
      if (released[0]) {
        console.log(
          `[payments/webhook] ${event} for the pending claim's ${merchantSubId} — released to ${released[0].merchant_subscription_id}`,
        );
      } else if (parked[0]) {
        c.executionCtx.waitUntil(
          reportPostHogSubscriptionCancel(env, {
            userId: parked[0].user_id,
            merchantSubId,
            reason: "webhook_revoked",
            priorStatus: parked[0].prior_status,
            occurredAt: parked[0].updated_at ?? null,
            pricePaise: parked[0].price_paise == null ? null : Number(parked[0].price_paise),
          }),
        );
      } else {
        await sql`
          UPDATE subscriptions
          SET superseded_mandate_id  = CASE WHEN superseded_mandate_id = ${merchantSubId}
                                            THEN NULL ELSE superseded_mandate_id END,
              superseded_price_paise = CASE WHEN superseded_mandate_id = ${merchantSubId}
                                            THEN NULL ELSE superseded_price_paise END,
              offer_mandate_id        = CASE WHEN offer_mandate_id = ${merchantSubId}
                                             THEN NULL ELSE offer_mandate_id END,
              revoke_retry_mandate_id = CASE WHEN revoke_retry_mandate_id = ${merchantSubId}
                                             THEN NULL ELSE revoke_retry_mandate_id END,
              revoke_retry_at         = CASE WHEN revoke_retry_mandate_id = ${merchantSubId}
                                             THEN NULL ELSE revoke_retry_at END,
              updated_at              = now()
          WHERE superseded_mandate_id = ${merchantSubId}
             OR offer_mandate_id = ${merchantSubId}
             OR revoke_retry_mandate_id = ${merchantSubId}
        `;
      }
    } else if (event === "subscription.paused") {
      // The mirror of the cron's park -> a status-only pause kept a debit clock no pass would ever serve
      await parkSubscription(env, sql, sql`s.merchant_subscription_id = ${merchantSubId}`, "paused");
    } else if (event === "subscription.unpaused") {
      await rearmUnpausedSubscription(sql, { merchantSubscriptionId: merchantSubId });
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

    if (kvKey) await env.KV.put(kvKey, "1", { expirationTtl: KV_TXN_TTL });
    return new Response("ok", { status: 200 });
  } catch (err) {
    console.error("[payments/webhook] DB error:", err);
    // 500 so PhonePe RETRIES -> a transient Neon fault on a completed setup used to be acked 200
    // Retrying is safe precisely because the idempotency mark is written ONLY on the success path
    return errorResponse(500, "server_error", "Temporary failure — please retry");
  } finally {
    c.executionCtx.waitUntil(Promise.allSettled(tails).then(() => sql.end()));
  }
}

export async function handleStatus(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  const tails: Promise<unknown>[] = [];
  try {
    const row = await readStatusRow(sql, sub);
    if (!row) {
      return c.json({ subscription: null, phonepe: null });
    }

    let phonePeStatus: { state: string; orderId?: string } | null = null;
    const merchantOrderId = row.merchant_order_id as string | null;

    // Scoped to 'pending' -> both reconcile branches below are no-ops for any other status
    // Calling PhonePe for a lapsed row spent a real API request that could never change an outcome
    // It matters because the paywall reconciles on EVERY open -> that is a lot of pointless calls
    if (merchantOrderId && (row.status as string) === "pending") {
      try {
        const orderStatus = await getOrderStatus(env, merchantOrderId);
        phonePeStatus = { state: orderStatus.state, orderId: orderStatus.orderId };

        // PhonePe says COMPLETED while we still say pending -> the webhook's grant, through the SAME function
        if (orderStatus.state === "COMPLETED") {
          const granted = await grantCompletedSetup(
            sql,
            sql`s.user_id = ${sub}`,
            orderStatus.paymentFlow?.subscriptionId ?? null,
          );
          if (granted) {
            tails.push(retireStaleMandate(env, sql, granted, "payments/status"));
            if (granted.kind === "grant" && granted.status === "active") {
              // The same paid-debit semantics as the webhook path -> idempotent, so both landing is harmless
              await grantReferralReward(sql, granted.user_id);
            }
            // The response is built from the SELECT taken BEFORE the grant -> re-read the one row it confirms
            Object.assign(row, await readStatusRow(sql, sub));
          }
        } else if (orderStatus.state === "FAILED" || orderStatus.state === "EXPIRED") {
          // Setup died at the UPI app -> the direct-intent flow's user-cancel lands HERE, with no SDK callback
          // Without this branch a cancelled intent setup polled its whole budget against a row nothing would flip
          const released = await releaseClaim(sql, sql`s.user_id = ${sub}`);
          if (released[0]) {
            Object.assign(row, await readStatusRow(sql, sub));
          } else {
            row.status = "expired";
          }
        }
      } catch (ppErr) {
        // The PhonePe call failed -> non-fatal -> answer from DB state alone rather than failing the poll
        console.warn("[payments/status] PhonePe order status failed:", ppErr);
      }
    }

    // Reconcile the live mandate for revoke/cancel AND pause/unpause -> a user acting in their UPI app fires no webhook
    // Scoped to these statuses -> the pending-setup poll above is not charged a second call, and free users cost nothing
    const liveMandateId = row.merchant_subscription_id as string | null;
    if (liveMandateId && ["trialing", "active", "paused"].includes(row.status as string)) {
      try {
        const subStatus = await getSubscriptionStatus(env, liveMandateId);
        phonePeStatus = phonePeStatus ?? { state: subStatus.state };
        if (subStatus.state === "CANCELLED" || subStatus.state === "REVOKED") {
          await parkSubscription(env, sql, sql`s.user_id = ${sub}`, "cancelled", "revoked_at_phonepe");
          row.status = "cancelled";
          // Mirror the write onto the response row -> otherwise it claims a debit is still coming on a revoked mandate
          row.next_debit_at = null;
        } else if (
          subStatus.state === "PAUSED" &&
          ((row.status as string) === "trialing" || (row.status as string) === "active")
        ) {
          await parkSubscription(env, sql, sql`s.user_id = ${sub}`, "paused");
          row.status = "paused";
          row.next_debit_at = null;
        } else if (subStatus.state === "ACTIVE" && (row.status as string) === "paused") {
          const restored = await rearmUnpausedSubscription(sql, {
            subscriptionId: row.id as string,
          });
          if (restored[0]) {
            row.status = restored[0].status;
            row.next_debit_at = restored[0].next_debit_at;
          }
        }
      } catch (ppErr) {
        console.warn("[payments/status] PhonePe subscription status failed:", ppErr);
      }
    }

    const redemptionOrderId = (row.redemption_order_id as string | null | undefined) ?? null;
    const trialEndAt = toDate(row.trial_end);
    const periodEndAt = toDate(row.current_period_end);
    const neverConverted =
      trialEndAt !== null && (periodEndAt === null || periodEndAt.getTime() <= trialEndAt.getTime());
    if (
      redemptionOrderId &&
      neverConverted &&
      ["pending", "cancelled", "expired", "paused"].includes(row.status as string)
    ) {
      try {
        const order = await getOrderStatus(env, redemptionOrderId);
        if (order.state === "COMPLETED") {
          const healed = await healSettledDebit(env, sql, sql`s.user_id = ${sub}`, redemptionOrderId);
          if (healed) {
            if (healed.prior_mandate_id && healed.prior_mandate_id !== healed.merchant_subscription_id) {
              revokeInBackground(c, healed.prior_mandate_id, "payments/status");
            }
            Object.assign(row, await readStatusRow(sql, sub));
          }
        }
      } catch (ppErr) {
        console.warn("[payments/status] redemption order status failed:", ppErr);
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
        price_paise: Number(row.price_paise ?? STANDARD_PRICE_PAISE),
      },
      phonepe: phonePeStatus,
    });
  } catch (err) {
    console.error("[payments/status] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(Promise.allSettled(tails).then(() => sql.end()));
  }
}

/** The status route's one row -> re-read after a transition so the response never reports pre-write values. */
async function readStatusRow(
  sql: ReturnType<typeof getDb>,
  sub: string,
): Promise<Record<string, unknown> | null> {
  const rows = (await sql`
    SELECT
      id, user_id, status, plan,
      merchant_subscription_id, merchant_order_id, phonepe_order_id,
      phonepe_subscription_id, current_period_end, trial_end,
      next_debit_at, notified_at, retry_count, updated_at,
      redemption_order_id, superseded_mandate_id, price_paise
    FROM subscriptions
    WHERE user_id = ${sub}
    LIMIT 1
  `) as unknown as Record<string, unknown>[];
  return rows[0] ?? null;
}

export async function handleCancel(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // The body is never read -> fielded builds post {offer_declined:true} or nothing, and either must still cancel
  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT merchant_subscription_id, superseded_mandate_id, offer_mandate_id, revoke_retry_mandate_id,
             status, offer_switch, trial_end, current_period_end
      FROM subscriptions
      WHERE user_id = ${sub}
      LIMIT 1
    `;

    if (rows.length === 0) {
      return errorResponse(404, "not_found", "No subscription to cancel");
    }

    const merchantSubId = rows[0].merchant_subscription_id as string | null;
    const parkedMandateId = (rows[0].superseded_mandate_id as string | null | undefined) ?? null;
    const offerMandateId = (rows[0].offer_mandate_id as string | null | undefined) ?? null;
    const retryMandateId = (rows[0].revoke_retry_mandate_id as string | null | undefined) ?? null;
    const status = rows[0].status as string;
    const pendingSwitch = status === "pending" && rows[0].offer_switch === true;

    if (status === "cancelled" || status === "expired") {
      // Already terminal -> answer success -> cancelling a cancelled subscription is not an error
      return c.json({ status, cancelled: true });
    }

    if (!merchantSubId) {
      return errorResponse(409, "no_mandate", "Subscription has no PhonePe mandate to revoke");
    }

    // Tolerates the already-inactive case -> a user who revoked in their UPI app is already at the desired end state
    // Only a mandate PhonePe still reports LIVE is a genuine failure worth asking the user to retry
    // A pending switch's ₹99 was never approved -> the parked ₹199 is what bills, and the ₹99 is watched, not waited on
    const required = [
      ...new Set(pendingSwitch ? [parkedMandateId] : [merchantSubId, parkedMandateId]),
    ].filter((id): id is string => id !== null);
    for (const id of required) {
      if (!(await revokeMandateTolerant(env, id))) {
        return errorResponse(502, "phonepe_error", "Could not cancel with PhonePe. Please try again.");
      }
    }
    // Never notified, so none of these can debit -> best effort, and a failed one stays on the row for the hourly sweep
    if (pendingSwitch) await revokeMandateTolerant(env, merchantSubId);
    const offerRevoked = offerMandateId === null || (await revokeMandateTolerant(env, offerMandateId));
    const retryRevoked = retryMandateId === null || (await revokeMandateTolerant(env, retryMandateId));

    // A pending switch goes back to the ₹199 it parked and keeps its unapproved ₹99 in offer_mandate_id, so a late
    // approval is revoked by the sweep, never resurrected into a month off a ₹2 check
    const cancelled = (await sql`
      UPDATE subscriptions AS s
      SET status                   = 'cancelled',
          merchant_subscription_id = CASE WHEN s.offer_switch
                                          THEN COALESCE(s.superseded_mandate_id, s.merchant_subscription_id)
                                          ELSE s.merchant_subscription_id END,
          price_paise              = CASE WHEN s.offer_switch AND s.superseded_mandate_id IS NOT NULL
                                          THEN COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE})
                                          ELSE s.price_paise END,
          offer_mandate_id         = CASE WHEN s.offer_switch THEN s.merchant_subscription_id
                                          WHEN ${offerRevoked}::boolean THEN NULL
                                          ELSE s.offer_mandate_id END,
          revoke_retry_mandate_id  = CASE WHEN ${retryRevoked}::boolean THEN NULL
                                          ELSE s.revoke_retry_mandate_id END,
          revoke_retry_at          = CASE WHEN ${retryRevoked}::boolean THEN NULL ELSE s.revoke_retry_at END,
          offer_switch             = false,
          superseded_mandate_id    = NULL,
          superseded_price_paise   = NULL,
          next_debit_at            = NULL,
          notified_at              = NULL,
          updated_at               = now()
      WHERE s.user_id = ${sub}
      RETURNING s.updated_at, s.price_paise, s.merchant_subscription_id
    `) as unknown as {
      updated_at?: Date | string | null;
      price_paise?: number | string | null;
      merchant_subscription_id?: string | null;
    }[];

    await reportPostHogSubscriptionCancel(env, {
      userId: sub,
      merchantSubId: cancelled[0]?.merchant_subscription_id ?? merchantSubId,
      reason: "user_cancel",
      // A pending switch ends the parked ₹199, which was live -> report the status it had, or the churn is dropped
      priorStatus: pendingSwitch ? switchParkedStatus(rows[0]) : status,
      occurredAt: cancelled[0]?.updated_at ?? null,
      pricePaise: cancelled[0]?.price_paise == null ? null : Number(cancelled[0].price_paise),
    });

    return c.json({ status: "cancelled", cancelled: true });
  } catch (err) {
    console.error("[payments/cancel] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

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
  const merchantOrderId = typeof body.merchantOrderId === "string" ? body.merchantOrderId.trim() : "";
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

    const released = await releaseClaim(
      sql,
      sql`s.user_id = ${sub} AND s.merchant_order_id = ${merchantOrderId}`,
    );

    // GUARDED ON THE RELEASE ACTUALLY FIRING -> zero rows means the row stopped being 'pending' mid-abandon
    // That is the grant landing between the read above and this write -> revoking there tears down a LIVE, paid mandate
    // The user would keep entitlement we can no longer bill -> the read-time checks cannot close this
    // The whole point is that the state changes underneath them
    const releasedMandateId = released[0]?.released_mandate_id ?? null;
    if (releasedMandateId) {
      c.executionCtx.waitUntil(
        revokeMandateTolerant(env, releasedMandateId).catch((err: unknown) => {
          console.warn(`[payments/abandon] revoke of ${releasedMandateId} threw:`, err);
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

// Authoritative state comes from the S2S webhook and the app's status poll -> this page decides NOTHING
// It exists only so the redirect does not 404, and to nudge the user back to the app

export function handleCallback(c: Context<{ Bindings: Env }>): Response {
  const html =
    `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<title>Arul</title></head><body style="font-family:system-ui;text-align:center;padding:48px 24px;color:#2B1116">` +
    `<h2 style="color:#1FA75A">Payment received</h2>` +
    `<p>You can return to the Arul app. Your subscription will activate in a moment.</p>` +
    `</body></html>`;
  return c.html(html);
}

function configuredMerchantId(env: Env, merchant: Merchant): string | null {
  try {
    return merchantKeys(env, merchant).merchantId;
  } catch {
    return null;
  }
}

/** `users.is_internal` is read only for the canary mode -> the default path spends no extra query. */
async function chooseSetupMerchant(
  env: Env,
  sql: ReturnType<typeof getDb>,
  userId: string,
): Promise<Merchant> {
  if (setupMerchantMode(env) !== "hsr-internal") return setupMerchant(env, false);
  const rows = (await sql`SELECT is_internal FROM users WHERE id = ${userId}`) as unknown as {
    is_internal?: boolean | null;
  }[];
  return setupMerchant(env, rows[0]?.is_internal === true);
}

/** Best-effort revoke OFF the response path -> a PhonePe hiccup must never fail the grant that triggered it. */
function revokeInBackground(c: Context<{ Bindings: Env }>, merchantSubId: string, tag: string): void {
  c.executionCtx.waitUntil(revokeTolerantly(c.env, merchantSubId, tag));
}

/** Never rejects -> it rides a request's tail, which must always reach sql.end(). */
function revokeTolerantly(env: Env, merchantSubId: string, tag: string): Promise<boolean> {
  return revokeMandateTolerant(env, merchantSubId)
    .then((revoked) => {
      if (!revoked) {
        console.error(
          `[${tag}] mandate ${merchantSubId} may STILL BE LIVE at PhonePe — manual revoke required`,
        );
      }
      return revoked;
    })
    .catch((err: unknown) => {
      console.error(`[${tag}] revoke of ${merchantSubId} threw:`, err);
      return false;
    });
}

/** The grant's replaced mandate, revoked after the response; one PhonePe keeps live is left for the hourly retry. */
function retireStaleMandate(
  env: Env,
  sql: ReturnType<typeof getDb>,
  grant: SetupGrant,
  tag: string,
): Promise<unknown> {
  const stale = grant.stale_mandate_id;
  if (!stale) return Promise.resolve();
  return revokeTolerantly(env, stale, tag)
    .then((revoked) =>
      revoked || grant.kind !== "switch" ? undefined : noteRevokeRetry(sql, grant.user_id, stale),
    )
    .catch((err: unknown) => console.error(`[${tag}] could not note ${stale} for a revoke retry:`, err));
}

/**
 * A completed setup for a ₹99 id the row no longer points at (released, or cancelled mid-switch) -> honour it while
 * the row is still on its ₹199 (decision 14), else revoke it. False = no row watches this id
 */
async function settleLateOffer(
  env: Env,
  sql: ReturnType<typeof getDb>,
  mandateId: string,
  phonepeSubId: string | null,
  tails: Promise<unknown>[],
): Promise<boolean> {
  const watched = await sql`SELECT 1 FROM subscriptions WHERE offer_mandate_id = ${mandateId} LIMIT 1`;
  if (watched.length === 0) return false;
  const honoured = await honourLateOfferApproval(sql, mandateId, phonepeSubId);
  if (honoured) {
    console.log(
      `[payments/webhook] late approval of ${mandateId} honoured — user ${honoured.user_id} is on ₹99`,
    );
    tails.push(retireStaleMandate(env, sql, honoured, "payments/webhook"));
  } else {
    console.warn(
      `[payments/webhook] late approval of ${mandateId} on a row no longer on its ₹199 — revoking it`,
    );
    tails.push(
      revokeTolerantly(env, mandateId, "payments/webhook").then(async (revoked) => {
        if (revoked)
          await sql`UPDATE subscriptions SET offer_mandate_id = NULL WHERE offer_mandate_id = ${mandateId}`;
      }),
    );
  }
  return true;
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
