/**
 * The endpoint table is docs/phonepe.md -> read it there, never from memory -> every shape here was verified live
 */

import type { Env } from "../env.js";

/**
 * Is this the production gateway? TRIMMED, and any unrecognised value THROWS. Both halves matter.
 * Defaulting to sandbox is never safe for a payment gateway -> a typo must fail loudly, never downgrade
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

/**
 * A non-2xx from PhonePe, carrying the HTTP status so callers can tell a TRANSIENT fault from a FINAL verdict.
 * The message format matches the plain Errors this replaced -> existing log greps and assertions still hit
 */
export class PhonePeApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: string,
  ) {
    super(message);
    this.name = "PhonePeApiError";
  }

  /**
   * True when PhonePe has decided -> retrying the identical call cannot succeed.
   * 429 is excluded on purpose -> it means "not now", never "never"
   */
  get isPermanent(): boolean {
    return this.status >= 400 && this.status < 500 && this.status !== 429;
  }
}

/** Exported for the safety test in test/phonepe-base.test.ts — see below. */
export function getPgBase(env: Env): string {
  // Local-dev escape hatch -> see Env.PHONEPE_BASE_URL_OVERRIDE and .claude/skills/verify-payments/
  // The PRODUCTION check MUST stay FIRST -> a live Worker returns the real host before the override is read
  // So no value of that var can redirect a real debit -> sandbox-only by construction, not by convention
  if (isProduction(env)) return "https://api.phonepe.com/apis/pg";
  return env.PHONEPE_BASE_URL_OVERRIDE || "https://api-preprod.phonepe.com/apis/pg-sandbox";
}

function getOAuthUrl(env: Env): string {
  return isProduction(env)
    ? "https://api.phonepe.com/apis/identity-manager/v1/oauth/token"
    : "https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token";
}

const OAUTH_KV_KEY = "phonepe:oauth";
const OAUTH_REFRESH_BUFFER_SECONDS = 60;

interface CachedToken {
  access_token: string;
  expires_at: number; // Unix epoch seconds
}

/**
 * The KV TTL is (expires_at - now - buffer) -> the entry disappears BEFORE the token could go invalid
 */
export async function getAccessToken(env: Env): Promise<string> {
  const cached = (await env.KV.get(OAUTH_KV_KEY, "json")) as CachedToken | null;
  if (cached) {
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (cached.expires_at - nowSeconds > OAUTH_REFRESH_BUFFER_SECONDS) {
      return cached.access_token;
    }
  }

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

  const data = (await res.json()) as {
    access_token: string;
    token_type: string;
    expires_at: number; // epoch seconds
  };

  if (!data.access_token) {
    throw new Error("PhonePe OAuth: missing access_token in response");
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const ttl = Math.max(30, data.expires_at - nowSeconds - OAUTH_REFRESH_BUFFER_SECONDS);
  const toCache: CachedToken = {
    access_token: data.access_token,
    expires_at: data.expires_at,
  };
  await env.KV.put(OAUTH_KV_KEY, JSON.stringify(toCache), { expirationTtl: ttl });

  return data.access_token;
}

async function authHeaders(env: Env): Promise<Record<string, string>> {
  const token = await getAccessToken(env);
  return {
    Authorization: `O-Bearer ${token}`,
    "Content-Type": "application/json",
  };
}

export interface SetupSubscriptionParams {
  userId: string;
  /** Unique merchant-generated subscription ID (≤63 chars, [A-Za-z0-9_-]) */
  merchantSubscriptionId: string;
  /** Unique merchant-generated order ID for this setup call (≤63 chars) */
  merchantOrderId: string;
  redirectUrl: string;
  /**
   * When set, the mandate is authorized via a REAL first debit of this amount
   * (authWorkflowType=TRANSACTION) instead of the ₹2 auto-reversed PENNY_DROP.
   * Docs: for TRANSACTION, `amount` = the first debit amount (≥100 paise).
   */
  upfrontAmountPaise?: number | undefined;
}

export interface SetupSubscriptionResult {
  orderId: string;
  state: string;
  /**
   * Web-checkout redirect URL. The mobile SDK returns the user via the app scheme instead, so it never reads this.
   * Create SDK Order usually omits it -> expect "" -> it is a future-web-flow fallback, nothing more
   */
  redirectUrl: string;
  /**
   * The SDK order token startTransaction() needs — the TOP-LEVEL `token` of /checkout/v2/sdk/order.
   */
  token: string | null;
  /** Epoch-ms expiry of the setup order -> the client shows its own timeout from this. */
  expireAt: number | null;
}

export async function setupSubscription(
  env: Env,
  params: SetupSubscriptionParams,
): Promise<SetupSubscriptionResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const upfront = params.upfrontAmountPaise;
  const body = {
    merchantOrderId: params.merchantOrderId,
    // PENNY_DROP -> exactly 200 paise, auto-reversed; TRANSACTION -> the actual first-debit amount
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
        maxAmount: 19900,
        frequency: "MONTHLY",
        productType: "UPI_MANDATE",
      },
    },
  };

  // MOBILE SDK -> the dedicated "Create SDK Order" endpoint, NEVER /checkout/v2/pay
  const res = await fetch(`${base}/checkout/v2/sdk/order`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new PhonePeApiError(`PhonePe setup error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as {
    orderId: string;
    state: string;
    token?: string;
    redirectUrl?: string;
    expireAt?: number;
  };

  // The top-level SDK order token is the ONLY source -> NEVER fall back to scraping ?token= out of redirectUrl
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

export interface SetupIntentParams {
  merchantOrderId: string;
  merchantSubscriptionId: string;
  targetApp: string;
  /** Present = trial consumed -> TRANSACTION with this real first debit. Absent = PENNY_DROP (₹2, auto-reversed). */
  upfrontAmountPaise?: number | undefined;
}

export interface SetupIntentResult {
  orderId: string;
  state: string;
  /** upi://mandate?… — launch as an ACTION_VIEW intent aimed at targetApp. */
  intentUrl: string;
}

/**
 * No intentUrl in a 200 is the missing-SDK-token trap again -> THROW so the caller falls back to the SDK page
 */
export async function setupSubscriptionIntent(
  env: Env,
  params: SetupIntentParams,
): Promise<SetupIntentResult> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);

  const upfront = params.upfrontAmountPaise;
  const body = {
    merchantOrderId: params.merchantOrderId,
    amount: upfront ?? 200,
    paymentFlow: {
      type: "SUBSCRIPTION_SETUP",
      merchantSubscriptionId: params.merchantSubscriptionId,
      authWorkflowType: upfront ? "TRANSACTION" : "PENNY_DROP",
      amountType: "FIXED",
      maxAmount: 19900, // ₹199 in paise — must match setupSubscription
      frequency: "MONTHLY",
      paymentMode: { type: "UPI_INTENT", targetApp: params.targetApp },
    },
    deviceContext: { deviceOS: "ANDROID" },
  };

  const res = await fetch(`${base}/subscriptions/v2/setup`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new PhonePeApiError(`PhonePe intent setup error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as {
    orderId: string;
    state: string;
    intentUrl?: string;
  };

  if (!data.intentUrl) {
    throw new Error(
      `PhonePe subscriptions/v2/setup returned no intentUrl ` +
        `(keys: ${Object.keys(data).join(",")}, state: ${data.state})`,
    );
  }

  return { orderId: data.orderId, state: data.state, intentUrl: data.intentUrl };
}

/**
 * Merchant-initiated cancellation of an active mandate. No request body; success is 204 No Content.
 */
export async function cancelSubscription(env: Env, merchantSubscriptionId: string): Promise<void> {
  const base = getPgBase(env);
  const headers = await authHeaders(env);
  const enc = encodeURIComponent(merchantSubscriptionId);

  // Direct merchant -> send ONLY the O-Bearer auth -> X-MERCHANT-ID is for PARTNER integrations and flips auth mode
  const candidates = [
    `${base}/subscriptions/v2/${enc}/cancel`,
    `${base}/checkout/v2/subscriptions/${enc}/cancel`,
  ];

  const failures: string[] = [];
  for (const url of candidates) {
    const res = await fetch(url, { method: "POST", headers });
    // Success is 204 No Content -> treat any 2xx as success
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
 * Cancel a mandate, tolerating the already-inactive case. True = confirmed no longer live.
 * PhonePe answers non-2xx when cancelling an already-inactive mandate -> that IS the desired end state
 * So on cancel failure, re-check the live state -> report failure only when PhonePe still says the mandate is live
 * A failed re-check also reports failure -> conservative on purpose -> the caller asks the user to retry
 */
export async function revokeMandateTolerant(env: Env, merchantSubscriptionId: string): Promise<boolean> {
  try {
    await cancelSubscription(env, merchantSubscriptionId);
    return true;
  } catch (ppErr) {
    console.warn("[revokeMandate] PhonePe cancel error:", ppErr);
    let stillLive = true;
    try {
      const st = await getSubscriptionStatus(env, merchantSubscriptionId);
      stillLive = st.state === "ACTIVE" || st.state === "ACTIVATION_IN_PROGRESS";
    } catch (statusErr) {
      // Scoped to NOT_FOUND on purpose -> a 401/5xx means "we cannot see" -> the conservative false stays right there
      if (
        statusErr instanceof PhonePeApiError &&
        (statusErr.status === 404 || statusErr.body.includes("SUBSCRIPTION_NOT_FOUND"))
      ) {
        stillLive = false;
      } else {
        console.warn("[revokeMandate] status re-check failed:", statusErr);
      }
    }
    return !stillLive;
  }
}

export interface NotifyRedemptionParams {
  merchantSubscriptionId: string;
  /** Unique order ID for this debit cycle (≤63 chars, [A-Za-z0-9_-]) */
  merchantOrderId: string;
  amountPaise: number;
}

export interface NotifyRedemptionResult {
  orderId: string;
  state: string;
  expireAt: number;
}

/**
 * POST /subscriptions/v2/notify — the mandatory 24h pre-debit announcement.
 *
 * Callers MUST confirm the subscription is ACTIVE first -> notifying a dead mandate wastes the window
 * redemptionRetryStrategy "STANDARD" makes PhonePe auto-retry for up to 48h
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
      // false -> WE call executeRedemption in cron Pass B -> the debit lands exactly at trial-end / period-end
      // The Execute API is only valid while autoDebit is DISABLED -> with true PhonePe debits on its own
      // A manual execute on top of that double-charges or errors -> the cron is built around explicit execute
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
    throw new PhonePeApiError(`PhonePe notify error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as {
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

export interface ExecuteRedemptionResult {
  state: string;
  transactionId: string;
}

/**
 * POST /subscriptions/v2/redeem — pass the SAME merchantOrderId notifyRedemption used, or the debit has no notice.
 * Callers MUST confirm the subscription is ACTIVE first
 */
export async function executeRedemption(env: Env, merchantOrderId: string): Promise<ExecuteRedemptionResult> {
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
    throw new PhonePeApiError(`PhonePe execute error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as {
    state: string;
    transactionId: string;
  };

  return {
    state: data.state,
    transactionId: data.transactionId,
  };
}

export interface SubscriptionStatusResult {
  merchantSubscriptionId: string;
  subscriptionId: string;
  state: string;
  authWorkflowType: string;
  amountType: string;
  maxAmount: string;
  frequency: string;
  expireAt: number | null;
}

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
        Authorization: `O-Bearer ${token}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new PhonePeApiError(`PhonePe subscription status error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as SubscriptionStatusResult;
  return data;
}

export interface OrderStatusResult {
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

export async function getOrderStatus(env: Env, merchantOrderId: string): Promise<OrderStatusResult> {
  const base = getPgBase(env);
  const token = await getAccessToken(env);

  const res = await fetch(
    `${base}/subscriptions/v2/order/${encodeURIComponent(merchantOrderId)}/status?details=true`,
    {
      method: "GET",
      headers: {
        Authorization: `O-Bearer ${token}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new PhonePeApiError(`PhonePe order status error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as OrderStatusResult;
  return data;
}

/** Identical to getOrderStatus — a distinct name only so redemption call sites read clearly. */
export async function getRedemptionStatus(env: Env, merchantOrderId: string): Promise<OrderStatusResult> {
  return getOrderStatus(env, merchantOrderId);
}

export interface RefundResult {
  refundId: string;
  amount: number;
  state: string;
}

/**
 * POST /payments/v2/refund — `originalMerchantOrderId` is the REDEMPTION order's id, never the setup order's.
 * `merchantRefundId` is ours to generate, <=63 chars of [A-Za-z0-9_-]; `amountPaise` may not exceed the original
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
    throw new PhonePeApiError(`PhonePe refund error ${res.status}: ${text}`, res.status, text);
  }

  const data = (await res.json()) as RefundResult;
  return data;
}

/**
 * Verify a PhonePe callback's Authorization header — a bare hex SHA256(username + ":" + password).
 * There is no scheme prefix, no signature over the body and no timestamp -> replay protection is ours (KV marks)
 */
export async function verifyCallbackAuth(
  authHeader: string,
  username: string,
  password: string,
): Promise<boolean> {
  const expected = await sha256Hex(`${username}:${password}`);
  return authHeader === expected;
}

/** @deprecated Use verifyCallbackAuth — same function, kept only so existing callers still compile. */
export async function verifyWebhookAuth(
  authHeader: string,
  username: string,
  password: string,
): Promise<boolean> {
  return verifyCallbackAuth(authHeader, username, password);
}

export interface PhonePeWebhookPayload {
  event?: string;
  /**
   * The SAME event in UPPER_SNAKE ("SUBSCRIPTION_REVOKED") — PhonePe sends one field or the other.
   * The handler normalizes `event ?? type` to dotted-lower -> both forms are accepted, neither is optional to read
   */
  type?: string;
  payload: {
    state: string;
    merchantId: string;
    merchantOrderId?: string;
    orderId?: string;
    amount?: number;
    expireAt?: number;
    /**
     * Read both homes, always through `merchantSubscriptionIdOf()` -> never reach for one field directly
     */
    merchantSubscriptionId?: string;
    subscriptionId?: string;
    paymentFlow?: {
      type?: string;
      merchantSubscriptionId?: string;
      subscriptionId?: string;
      amountType?: string;
      maxAmount?: number;
      frequency?: string;
    };
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

export function merchantSubscriptionIdOf(
  pp: PhonePeWebhookPayload["payload"] | undefined,
): string | undefined {
  return pp?.merchantSubscriptionId ?? pp?.paymentFlow?.merchantSubscriptionId;
}

export function phonePeSubscriptionIdOf(pp: PhonePeWebhookPayload["payload"] | undefined): string | null {
  return pp?.subscriptionId ?? pp?.paymentFlow?.subscriptionId ?? null;
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * DKS_S_<userId-first-8>_<epoch-ms-base36>. PhonePe caps these at 63 chars of [A-Za-z0-9_-].
 */
export function buildMerchantSubscriptionId(userId: string): string {
  const shortId = userId.replace(/-/g, "").slice(0, 8).toUpperCase();
  const ts = Date.now().toString(36).toUpperCase();
  return `DKS_S_${shortId}_${ts}`;
}

/** DKS_<tag>_<userId-first-8>_<epoch-ms-base36>_<4-random-hex> — the random tail separates two calls in one ms. */
export function buildMerchantOrderId(userId: string, tag = "O"): string {
  const shortId = userId.replace(/-/g, "").slice(0, 8).toUpperCase();
  const ts = Date.now().toString(36).toUpperCase();
  const rnd = Math.floor(Math.random() * 0xffff)
    .toString(16)
    .toUpperCase()
    .padStart(4, "0");
  return `DKS_${tag}_${shortId}_${ts}_${rnd}`;
}
