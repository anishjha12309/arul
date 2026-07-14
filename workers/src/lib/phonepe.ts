/**
 * PhonePe Payment Gateway — Standard Checkout v2 (OAuth / O-Bearer)
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * This file implements the PhonePe Autopay v2 OAuth API.  Every request shape
 * was verified against the live developer docs before coding.
 *
 * Verified API reference URLs:
 *
 *   OAuth token
 *     https://developer.phonepe.com/payment-gateway/autopay/api-integration/api-reference/authorization
 *     Sandbox:    POST https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token
 *     Production: POST https://api.phonepe.com/apis/identity-manager/v1/oauth/token
 *     Content-Type: application/x-www-form-urlencoded
 *     Body: client_id, client_secret, client_version, grant_type=client_credentials
 *     Response: access_token, token_type ("O-Bearer"), issued_at, expires_at (epoch s)
 *
 *   Setup subscription — MOBILE SDK via Create SDK Order (/checkout/v2/sdk/order)
 *     https://developer.phonepe.com/payment-gateway/autopay/standard-checkout/setup-subscription/api-integration
 *     https://developer.phonepe.com/payment-gateway/mobile-app-integration/standard-checkout-mobile/flutter/sdk-setup
 *     Auth header: Authorization: O-Bearer <access_token>
 *     Top-level: merchantOrderId (≤63 chars, [A-Za-z0-9_-]), amount (200 for PENNY_DROP), paymentFlow
 *     paymentFlow.type = "SUBSCRIPTION_CHECKOUT_SETUP"
 *     paymentFlow.merchantUrls.redirectUrl required
 *     paymentFlow.subscriptionDetails: subscriptionType="RECURRING", merchantSubscriptionId,
 *       authWorkflowType="PENNY_DROP", amountType="FIXED", maxAmount=19900,
 *       frequency="MONTHLY", productType="UPI_MANDATE"
 *     Response: orderId, state ("PENDING"), token (SDK order token), expireAt
 *     NOTE: /checkout/v2/pay (web flow) returns a mercury redirectUrl whose
 *       ?token= is a WEB page token — feeding it to the mobile SDK gives PR004/401.
 *       The mobile SDK MUST use /checkout/v2/sdk/order, which returns a top-level
 *       `token`. Both accept the identical body. Verified live on prod 2026-07-02.
 *
 *   Notify redemption
 *     https://developer.phonepe.com/payment-gateway/autopay/api-integration/api-reference/redemption-notify
 *     POST {base}/subscriptions/v2/notify
 *     Body: merchantOrderId, amount (19900), paymentFlow.type="SUBSCRIPTION_REDEMPTION",
 *       paymentFlow.merchantSubscriptionId, paymentFlow.redemptionRetryStrategy="STANDARD",
 *       paymentFlow.autoDebit=false  (we call executeRedemption ourselves — see notifyRedemption)
 *     Response: orderId, state ("NOTIFICATION_IN_PROGRESS"), expireAt
 *
 *   Execute redemption
 *     https://developer.phonepe.com/payment-gateway/autopay/api-integration/api-reference/redemption-execute
 *     POST {base}/subscriptions/v2/redeem
 *     Body: merchantOrderId (same one used in notify)
 *     Response: state ("PENDING"|"COMPLETED"|"FAILED"), transactionId
 *
 *   Subscription status
 *     GET {base}/subscriptions/v2/{merchantSubscriptionId}/status?details=true
 *     Response: merchantSubscriptionId, subscriptionId, state
 *       (ACTIVE | ACTIVATION_IN_PROGRESS | EXPIRED | FAILED | CANCELLED | REVOKED | PAUSED | …)
 *
 *   Order status (setup and redemption orders)
 *     GET {base}/subscriptions/v2/order/{merchantOrderId}/status?details=true
 *     Response: state (COMPLETED | FAILED | PENDING), orderId, amount, paymentFlow, paymentDetails
 *
 *   Refund
 *     https://developer.phonepe.com/payment-gateway/autopay/api-integration/api-reference/refund
 *     POST {base}/payments/v2/refund
 *     Body: merchantRefundId, originalMerchantOrderId, amount (paise)
 *     Response: refundId, amount, state (PENDING | COMPLETED | FAILED)
 *
 *   Webhook auth (all event callbacks)
 *     https://developer.phonepe.com/payment-gateway/autopay/standard-checkout/webhook-handling
 *     Authorization header value = SHA256(username + ":" + password) hex
 *     Event types: checkout.order.completed | checkout.order.failed
 *       subscription.notification.completed | subscription.notification.failed
 *       subscription.redemption.order.completed | subscription.redemption.order.failed
 *       subscription.redemption.transaction.completed | subscription.redemption.transaction.failed
 *       subscription.paused | subscription.unpaused | subscription.revoked | subscription.cancelled
 *       pg.refund.accepted | pg.refund.completed | pg.refund.failed
 *     Payload top-level: event, payload.{ state, merchantId, merchantOrderId, orderId, amount,
 *       expireAt, merchantSubscriptionId, subscriptionId, errorCode, detailedErrorCode,
 *       paymentDetails[] }
 * ─────────────────────────────────────────────────────────────────────────────
 */

import type { Env } from "../env.js";

// ── Hosts ─────────────────────────────────────────────────────────────────────

/**
 * Is this the production gateway?
 *
 * TRIMMED, and anything that is not a recognised value THROWS. Both matter:
 * a secret set through a shell pipe easily picks up a trailing newline, and the
 * old bare `=== "PRODUCTION"` then quietly fell through to the SANDBOX branch —
 * so production credentials got posted to the preprod host and came back
 * `401 {"code":"401"}`, which reads exactly like "bad credentials" and sends you
 * hunting the wrong bug. Silently defaulting to sandbox is never the safe
 * default for a payment gateway; a typo must fail loudly, not downgrade.
 */
function isProduction(env: Env): boolean {
  const raw = (env.PHONEPE_ENV ?? "").trim().toUpperCase();
  if (raw !== "PRODUCTION" && raw !== "SANDBOX") {
    throw new Error(
      `PHONEPE_ENV must be exactly "PRODUCTION" or "SANDBOX" (got ${JSON.stringify(env.PHONEPE_ENV)}).`,
    );
  }
  return raw === "PRODUCTION";
}

function getPgBase(env: Env): string {
  return isProduction(env)
    ? "https://api.phonepe.com/apis/pg"
    : "https://api-preprod.phonepe.com/apis/pg-sandbox";
}

function getOAuthUrl(env: Env): string {
  return isProduction(env)
    ? "https://api.phonepe.com/apis/identity-manager/v1/oauth/token"
    : "https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token";
}

// ── OAuth token (KV-cached) ───────────────────────────────────────────────────

const OAUTH_KV_KEY = "phonepe:oauth";
/** Refresh the token this many seconds before it actually expires. */
const OAUTH_REFRESH_BUFFER_SECONDS = 60;

interface CachedToken {
  access_token: string;
  expires_at: number; // Unix epoch seconds
}

/**
 * Return a valid O-Bearer access token, refreshing from PhonePe only when
 * the cached one is within OAUTH_REFRESH_BUFFER_SECONDS of expiry.
 *
 * KV key: "phonepe:oauth"
 * KV TTL is set to (expires_at - now - buffer) seconds so the entry naturally
 * disappears before the token becomes invalid.
 */
export async function getAccessToken(env: Env): Promise<string> {
  // 1. Try cache
  const cached = await env.KV.get(OAUTH_KV_KEY, "json") as CachedToken | null;
  if (cached) {
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (cached.expires_at - nowSeconds > OAUTH_REFRESH_BUFFER_SECONDS) {
      return cached.access_token;
    }
  }

  // 2. Fetch new token. Trimmed for the same reason as PHONEPE_ENV: a secret
  // uploaded through a shell pipe can carry a trailing newline, and URLSearchParams
  // would faithfully encode it into the credential (%0A), yielding a 401 that
  // looks like a wrong password rather than a stray byte.
  const body = new URLSearchParams({
    client_id: env.PHONEPE_CLIENT_ID.trim(),
    client_secret: env.PHONEPE_CLIENT_SECRET.trim(),
    client_version: env.PHONEPE_CLIENT_VERSION.trim(),
    grant_type: "client_credentials",
  });

  const res = await fetch(getOAuthUrl(env), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe OAuth error ${res.status}: ${text}`);
  }

  const data = await res.json() as {
    access_token: string;
    token_type: string;
    expires_at: number; // epoch seconds
  };

  if (!data.access_token) {
    throw new Error("PhonePe OAuth: missing access_token in response");
  }

  // 3. Cache it — TTL = remaining lifetime minus buffer (min 30s)
  const nowSeconds = Math.floor(Date.now() / 1000);
  const ttl = Math.max(30, data.expires_at - nowSeconds - OAUTH_REFRESH_BUFFER_SECONDS);
  const toCache: CachedToken = {
    access_token: data.access_token,
    expires_at: data.expires_at,
  };
  await env.KV.put(OAUTH_KV_KEY, JSON.stringify(toCache), { expirationTtl: ttl });

  return data.access_token;
}

// ── Auth header helper ────────────────────────────────────────────────────────

async function authHeaders(env: Env): Promise<Record<string, string>> {
  const token = await getAccessToken(env);
  return {
    "Authorization": `O-Bearer ${token}`,
    "Content-Type": "application/json",
  };
}

// ── Setup subscription (PENNY_DROP, /checkout/v2/pay) ─────────────────────────

export interface SetupSubscriptionParams {
  /** Our internal user UUID — used to build merchant IDs */
  userId: string;
  /** Unique merchant-generated subscription ID (≤63 chars, [A-Za-z0-9_-]) */
  merchantSubscriptionId: string;
  /** Unique merchant-generated order ID for this setup call (≤63 chars) */
  merchantOrderId: string;
  /** URL PhonePe redirects to after the user completes the mandate */
  redirectUrl: string;
  /**
   * When set, the mandate is authorized via a REAL first debit of this amount
   * (authWorkflowType=TRANSACTION) instead of the ₹2 auto-reversed PENNY_DROP.
   * Used for trial-consumed users: they pay ₹199 upfront, no second free trial.
   * Docs: for TRANSACTION, `amount` = the first debit amount (≥100 paise).
   */
  upfrontAmountPaise?: number | undefined;
}

export interface SetupSubscriptionResult {
  /** PhonePe-generated order ID */
  orderId: string;
  /** Typically "PENDING" immediately after setup */
  state: string;
  /**
   * Web-checkout redirect URL. The mobile SDK does NOT use this (it returns the
   * user via the app scheme). Present only as a fallback / for a future web flow;
   * the Create SDK Order response usually omits it, so this is often "".
   */
  redirectUrl: string;
  /**
   * The SDK order token the Flutter SDK's startTransaction() needs. Comes from
   * the top-level `token` field of the Create SDK Order response
   * (/checkout/v2/sdk/order) — NOT the mercury web `redirectUrl?token=`, which
   * is a web-page token the SDK rejects with PR004/401. Null only if PhonePe
   * returns neither a token nor a scrapeable redirectUrl.
   */
  token: string | null;
  /** Epoch-ms expiry of the setup order (for client-side timeout UX). */
  expireAt: number | null;
}

/**
 * Initiate a subscription mandate.
 *
 * Default (trial-eligible user) — PENNY_DROP:
 *   amount = 200 paise (MUST be exactly 200; ₹2 auto-reversed), 1-day free
 *   trial granted on completion, first real debit next day via the cron.
 *
 * upfrontAmountPaise set (trial already consumed) — TRANSACTION:
 *   amount = upfrontAmountPaise (the REAL first debit, charged during setup);
 *   on completion the user is immediately 'active' for one month. Verified
 *   against the setup-subscription docs 2026-07-04: for TRANSACTION the
 *   top-level `amount` is the first debit amount (≥100 paise).
 *
 * Common: maxAmount = 19900 (₹199), frequency = MONTHLY, productType = UPI_MANDATE.
 */
export async function setupSubscription(
  env: Env,
  params: SetupSubscriptionParams,
): Promise<SetupSubscriptionResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const upfront = params.upfrontAmountPaise;
  const body = {
    merchantOrderId: params.merchantOrderId,
    // PENNY_DROP: exactly 200 paise = ₹2 (auto-reversed).
    // TRANSACTION: the actual first-debit amount.
    amount: upfront ?? 200,
    paymentFlow: {
      type: "SUBSCRIPTION_CHECKOUT_SETUP",
      merchantUrls: {
        redirectUrl: params.redirectUrl,
      },
      subscriptionDetails: {
        subscriptionType: "RECURRING",
        merchantSubscriptionId: params.merchantSubscriptionId,
        authWorkflowType: upfront ? "TRANSACTION" : "PENNY_DROP",
        amountType: "FIXED",
        maxAmount: 19900, // ₹199 in paise
        frequency: "MONTHLY",
        productType: "UPI_MANDATE",
      },
    },
  };

  // MOBILE SDK: use the dedicated "Create SDK Order" endpoint, NOT /checkout/v2/pay.
  // /checkout/v2/pay returns only a mercury web-checkout redirectUrl whose
  // ?token=… is a WEB PAGE token; handing that to the Flutter SDK's
  // startTransaction makes the SDK's internal PG_PAY_V2_SIMPLE call return
  // HTTP 401 / PR004 "Unauthorized". /checkout/v2/sdk/order accepts the SAME
  // subscription body and returns a top-level `token` that IS the SDK order
  // token startTransaction requires. Verified live against prod on 2026-07-02:
  //   POST /apis/pg/checkout/v2/pay        → { orderId, state, redirectUrl, expireAt }  (no token)
  //   POST /apis/pg/checkout/v2/sdk/order  → { orderId, state, expireAt, token }        (HTTP 200)
  // Ref: developer.phonepe.com — Create SDK Order (Standard Checkout mobile).
  const res = await fetch(`${base}/checkout/v2/sdk/order`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe setup error ${res.status}: ${text}`);
  }

  const data = await res.json() as {
    orderId: string;
    state: string;
    token?: string;
    redirectUrl?: string;
    expireAt?: number;
  };

  // Primary source is the top-level SDK order token.
  //
  // The old code fell back to scraping ?token= out of `redirectUrl` when the
  // top-level token was absent. That "graceful degradation" is a trap: the
  // scraped value is a WEB CHECKOUT token, and per the note above, handing one
  // to the Flutter SDK is precisely what produces 401 / PR004 "Unauthorized" on
  // device. The fallback turned a loud, diagnosable server failure into a 200
  // carrying a token guaranteed to fail — the worst of both. If sdk/order did
  // not return a token, that IS the bug; say so here rather than shipping a
  // poisoned one to the SDK.
  const token: string | null = data.token ?? null;
  if (!token) {
    throw new Error(
      `PhonePe sdk/order returned no SDK token (keys: ${Object.keys(data).join(",")}, ` +
        `state: ${data.state}). A web-checkout token cannot authorize the mobile SDK.`,
    );
  }

  return {
    orderId: data.orderId,
    state: data.state,
    redirectUrl: data.redirectUrl ?? "",
    token,
    expireAt: data.expireAt ?? null,
  };
}

// ── Cancel (revoke) subscription ──────────────────────────────────────────────

/**
 * POST {base}/checkout/v2/subscriptions/{merchantSubscriptionId}/cancel
 *
 * Merchant-initiated cancellation of an active mandate. No request body.
 * Success = HTTP 204 No Content. After this, no further debits are triggered;
 * confirm via getSubscriptionStatus (state → CANCELLED) or the
 * subscription.cancelled webhook.
 *
 * Verified: https://developer.phonepe.com/payment-gateway/autopay/standard-checkout/subscription-cancel
 *   Sandbox:    https://api-preprod.phonepe.com/apis/pg-sandbox/checkout/v2/subscriptions/{id}/cancel
 *   Production: https://api.phonepe.com/apis/pg/checkout/v2/subscriptions/{id}/cancel
 */
export async function cancelSubscription(
  env: Env,
  merchantSubscriptionId: string,
): Promise<void> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);
  const enc = encodeURIComponent(merchantSubscriptionId);

  // Direct merchant → send ONLY the O-Bearer auth (no X-MERCHANT-ID; that header
  // is for PARTNER integrations and flips PhonePe into partner auth).
  //
  // Endpoint gotcha (verified live on prod 2026-07-02): PhonePe's DOCUMENTED
  // Standard-Checkout cancel path — /checkout/v2/subscriptions/{id}/cancel —
  // returns 401 AUTHORIZATION_FAILED for our OAuth client even though the SAME
  // token succeeds on /subscriptions/v2/* (notify/redeem/status). The working
  // cancel is /subscriptions/v2/{id}/cancel, so that's primary; the documented
  // path is kept only as a fallback in case PhonePe changes/enables it.
  const candidates = [
    `${base}/subscriptions/v2/${enc}/cancel`,
    `${base}/checkout/v2/subscriptions/${enc}/cancel`,
  ];

  const failures: string[] = [];
  for (const url of candidates) {
    const res = await fetch(url, { method: "POST", headers });
    // 204 No Content = success. Treat any 2xx as success.
    if (res.ok) {
      if (failures.length > 0) {
        console.warn(`[cancelSubscription] succeeded via ${url} after: ${failures.join(" | ")}`);
      }
      return;
    }
    const text = await res.text();
    failures.push(`${url} -> ${res.status}: ${text}`);
  }

  console.warn(`[cancelSubscription][DIAG] all cancel paths failed: ${failures.join(" || ")}`);
  throw new Error(`PhonePe cancel error: ${failures[0]}`);
}

/**
 * Cancel a mandate, tolerating the already-inactive case.
 *
 * PhonePe returns non-2xx when cancelling a mandate that is already inactive
 * (e.g. the user revoked it from their UPI app — bank-initiated revokes often
 * do NOT fire a merchant webhook, so our row can still read live). That IS the
 * desired end state, so on cancel failure we re-check the live state and only
 * report failure when PhonePe still says the mandate is live (or the re-check
 * itself failed — conservative: caller should ask the user to retry).
 *
 * @returns true when the mandate is confirmed no longer live.
 */
export async function revokeMandateTolerant(
  env: Env,
  merchantSubscriptionId: string,
): Promise<boolean> {
  try {
    await cancelSubscription(env, merchantSubscriptionId);
    return true;
  } catch (ppErr) {
    console.warn("[revokeMandate] PhonePe cancel error:", ppErr);
    let stillLive = true;
    try {
      const st = await getSubscriptionStatus(env, merchantSubscriptionId);
      stillLive =
        st.state === "ACTIVE" || st.state === "ACTIVATION_IN_PROGRESS";
    } catch (statusErr) {
      console.warn("[revokeMandate] status re-check failed:", statusErr);
    }
    return !stillLive;
  }
}

// ── Notify redemption ─────────────────────────────────────────────────────────

export interface NotifyRedemptionParams {
  merchantSubscriptionId: string;
  /** Unique order ID for this debit cycle (≤63 chars, [A-Za-z0-9_-]) */
  merchantOrderId: string;
  /** Amount in paise — 19900 for ₹199 */
  amountPaise: number;
}

export interface NotifyRedemptionResult {
  orderId: string;
  state: string;
  expireAt: number;
}

/**
 * POST /subscriptions/v2/notify
 *
 * Must be called 24h before the debit date.
 * IMPORTANT: verify the subscription is ACTIVE (getSubscriptionStatus) before calling.
 * PhonePe auto-retries up to 48h when redemptionRetryStrategy = "STANDARD".
 */
export async function notifyRedemption(
  env: Env,
  params: NotifyRedemptionParams,
): Promise<NotifyRedemptionResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const body = {
    merchantOrderId: params.merchantOrderId,
    amount: params.amountPaise,
    paymentFlow: {
      type: "SUBSCRIPTION_REDEMPTION",
      merchantSubscriptionId: params.merchantSubscriptionId,
      redemptionRetryStrategy: "STANDARD",
      // false = WE call executeRedemption explicitly (cron Pass B), giving
      // deterministic control over WHEN the debit lands (trial-end / period-end).
      // PhonePe docs: Execute API must only be called when autoDebit is DISABLED;
      // with autoDebit=true PhonePe debits on its own and a manual execute would
      // double-charge/error. Our cron is built around explicit execute, so: false.
      autoDebit: false,
    },
  };

  const res = await fetch(`${base}/subscriptions/v2/notify`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe notify error ${res.status}: ${text}`);
  }

  const data = await res.json() as {
    orderId: string;
    state: string;
    expireAt: number;
  };

  return {
    orderId: data.orderId,
    state: data.state,
    expireAt: data.expireAt,
  };
}

// ── Execute redemption ────────────────────────────────────────────────────────

export interface ExecuteRedemptionResult {
  state: string; // PENDING | COMPLETED | FAILED
  transactionId: string;
}

/**
 * POST /subscriptions/v2/redeem
 *
 * Pass the same merchantOrderId used in notifyRedemption.
 * IMPORTANT: verify subscription is ACTIVE before calling.
 */
export async function executeRedemption(
  env: Env,
  merchantOrderId: string,
): Promise<ExecuteRedemptionResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const body = { merchantOrderId };

  const res = await fetch(`${base}/subscriptions/v2/redeem`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe execute error ${res.status}: ${text}`);
  }

  const data = await res.json() as {
    state: string;
    transactionId: string;
  };

  return {
    state: data.state,
    transactionId: data.transactionId,
  };
}

// ── Subscription status ───────────────────────────────────────────────────────

export interface SubscriptionStatusResult {
  merchantSubscriptionId: string;
  subscriptionId: string;
  /** ACTIVE | ACTIVATION_IN_PROGRESS | EXPIRED | FAILED | CANCELLED | REVOKED | PAUSED | … */
  state: string;
  authWorkflowType: string;
  amountType: string;
  maxAmount: string;
  frequency: string;
  expireAt: number | null;
}

/**
 * GET /subscriptions/v2/{merchantSubscriptionId}/status?details=true
 */
export async function getSubscriptionStatus(
  env: Env,
  merchantSubscriptionId: string,
): Promise<SubscriptionStatusResult> {
  const base = getPgBase(env);
  const token = await getAccessToken(env);

  const res = await fetch(
    `${base}/subscriptions/v2/${encodeURIComponent(merchantSubscriptionId)}/status?details=true`,
    {
      method: "GET",
      headers: {
        "Authorization": `O-Bearer ${token}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe subscription status error ${res.status}: ${text}`);
  }

  const data = await res.json() as SubscriptionStatusResult;
  return data;
}

// ── Order status (setup orders + redemption orders) ───────────────────────────

export interface OrderStatusResult {
  /** COMPLETED | FAILED | PENDING */
  state: string;
  orderId: string;
  merchantOrderId: string;
  merchantId: string;
  amount: number;
  currency: string;
  expireAt: number;
  errorCode?: string;
  detailedErrorCode?: string;
  paymentFlow?: {
    type: string;
    merchantSubscriptionId?: string;
    subscriptionId?: string;
  };
}

/**
 * GET /subscriptions/v2/order/{merchantOrderId}/status?details=true
 * Works for both setup orders and redemption orders.
 */
export async function getOrderStatus(
  env: Env,
  merchantOrderId: string,
): Promise<OrderStatusResult> {
  const base = getPgBase(env);
  const token = await getAccessToken(env);

  const res = await fetch(
    `${base}/subscriptions/v2/order/${encodeURIComponent(merchantOrderId)}/status?details=true`,
    {
      method: "GET",
      headers: {
        "Authorization": `O-Bearer ${token}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe order status error ${res.status}: ${text}`);
  }

  const data = await res.json() as OrderStatusResult;
  return data;
}

// ── Redemption status (alias — same endpoint as order status) ─────────────────

/**
 * Check the status of a redemption order.
 * Identical to getOrderStatus — provided as a distinct function for clarity.
 */
export async function getRedemptionStatus(
  env: Env,
  merchantOrderId: string,
): Promise<OrderStatusResult> {
  return getOrderStatus(env, merchantOrderId);
}

// ── Refund ────────────────────────────────────────────────────────────────────

export interface RefundResult {
  refundId: string;
  amount: number;
  /** PENDING | COMPLETED | FAILED */
  state: string;
}

/**
 * POST /payments/v2/refund
 *
 * @param originalMerchantOrderId  merchantOrderId of the original redemption order
 * @param merchantRefundId         unique refund ID you generate (≤63 chars, [A-Za-z0-9_-])
 * @param amountPaise              refund amount in paise (≤ original transaction amount)
 */
export async function initiateRefund(
  env: Env,
  originalMerchantOrderId: string,
  merchantRefundId: string,
  amountPaise: number,
): Promise<RefundResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const body = {
    merchantRefundId,
    originalMerchantOrderId,
    amount: amountPaise,
  };

  const res = await fetch(`${base}/payments/v2/refund`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PhonePe refund error ${res.status}: ${text}`);
  }

  const data = await res.json() as RefundResult;
  return data;
}

// ── Webhook callback auth verification ───────────────────────────────────────

/**
 * Verify a PhonePe Autopay v2 callback Authorization header.
 *
 * PhonePe sends:  Authorization: <hex>
 * where <hex> = SHA256(username + ":" + password)
 *
 * Source: https://developer.phonepe.com/payment-gateway/autopay/standard-checkout/webhook-handling
 */
export async function verifyCallbackAuth(
  authHeader: string,
  username: string,
  password: string,
): Promise<boolean> {
  const expected = await sha256Hex(`${username}:${password}`);
  return authHeader === expected;
}

/**
 * @deprecated Use verifyCallbackAuth — same function, kept for backwards compat.
 */
export async function verifyWebhookAuth(
  authHeader: string,
  username: string,
  password: string,
): Promise<boolean> {
  return verifyCallbackAuth(authHeader, username, password);
}

// ── Webhook payload types ─────────────────────────────────────────────────────

/**
 * Shape of a PhonePe Autopay v2 webhook POST body.
 *
 * Event types (source: webhook-handling docs):
 *   Setup:       checkout.order.completed | checkout.order.failed
 *   Notify:      subscription.notification.completed | subscription.notification.failed
 *   Redemption:  subscription.redemption.order.completed | subscription.redemption.order.failed
 *                subscription.redemption.transaction.completed | subscription.redemption.transaction.failed
 *   State:       subscription.paused | subscription.unpaused | subscription.revoked | subscription.cancelled
 *   Refund:      pg.refund.accepted | pg.refund.completed | pg.refund.failed
 */
export interface PhonePeWebhookPayload {
  /** e.g. "checkout.order.completed" (dotted-lower form). */
  event?: string;
  /**
   * Alternate field PhonePe uses in some payloads, UPPER_SNAKE
   * (e.g. "SUBSCRIPTION_REVOKED"). The webhook handler normalizes event ?? type
   * to the dotted-lower form, so either is accepted.
   */
  type?: string;
  payload: {
    /** Order/subscription state */
    state: string;
    merchantId: string;
    merchantOrderId?: string;
    orderId?: string;
    amount?: number;
    expireAt?: number;
    merchantSubscriptionId?: string;
    subscriptionId?: string;
    errorCode?: string;
    detailedErrorCode?: string;
    paymentDetails?: Array<{
      transactionId?: string;
      paymentMode?: string;
      timestamp?: number;
      state?: string;
    }>;
  };
}

// ── Internal helpers ──────────────────────────────────────────────────────────

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// ── Merchant ID generators ────────────────────────────────────────────────────

/**
 * Build a merchant subscription ID that is:
 *   - ≤ 63 characters
 *   - Only [A-Za-z0-9_-]
 *   - Unique per user + timestamp
 *
 * Format: DKS_S_<userId-first-8-chars>_<epoch-ms-base36>
 * Example: DKS_S_a1b2c3d4_lzzzzzzzz  (≤ 36 chars comfortably)
 */
export function buildMerchantSubscriptionId(userId: string): string {
  const shortId = userId.replace(/-/g, "").slice(0, 8).toUpperCase();
  const ts = Date.now().toString(36).toUpperCase();
  return `DKS_S_${shortId}_${ts}`;
}

/**
 * Build a unique merchant order ID.
 * Format: DKS_O_<userId-first-8>_<epoch-ms-base36>_<4-random-hex>
 * Always ≤ 63 chars.
 */
export function buildMerchantOrderId(userId: string, tag = "O"): string {
  const shortId = userId.replace(/-/g, "").slice(0, 8).toUpperCase();
  const ts = Date.now().toString(36).toUpperCase();
  const rnd = Math.floor(Math.random() * 0xffff).toString(16).toUpperCase().padStart(4, "0");
  return `DKS_${tag}_${shortId}_${ts}_${rnd}`;
}
