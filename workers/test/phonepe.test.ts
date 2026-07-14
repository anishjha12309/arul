/**
 * Unit tests for PhonePe Standard Checkout v2 (OAuth / O-Bearer) helpers.
 *
 * Coverage:
 *   - getAccessToken: KV caching, refresh, error handling
 *   - setupSubscription: exact request payload (PENNY_DROP amount=200, maxAmount=19900,
 *     frequency=MONTHLY, authWorkflowType=PENNY_DROP, productType=UPI_MANDATE)
 *   - notifyRedemption: exact payload (type=SUBSCRIPTION_REDEMPTION,
 *     redemptionRetryStrategy=STANDARD, autoDebit=true, amount=19900)
 *   - executeRedemption: passes merchantOrderId, returns state+transactionId
 *   - initiateRefund: merchantRefundId, originalMerchantOrderId, amount
 *   - verifyCallbackAuth / verifyWebhookAuth: SHA256(username:password) hex comparison
 *   - buildMerchantSubscriptionId / buildMerchantOrderId: format and length constraints
 *
 * No real network calls — fetch and KV are mocked.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  getAccessToken,
  setupSubscription,
  cancelSubscription,
  notifyRedemption,
  executeRedemption,
  initiateRefund,
  getSubscriptionStatus,
  getOrderStatus,
  verifyCallbackAuth,
  verifyWebhookAuth,
  buildMerchantSubscriptionId,
  buildMerchantOrderId,
} from "../src/lib/phonepe.js";
import type { Env } from "../src/env.js";

// ── Mock helpers ──────────────────────────────────────────────────────────────

function makeMockKV(initial?: Map<string, string>): KVNamespace {
  const store = initial ?? new Map<string, string>();
  return {
    put: vi.fn(async (key: string, value: string) => { store.set(key, value); }),
    // Mirrors real KV: when type="json", parse and return the object; otherwise return string.
    get: vi.fn(async (key: string, type?: string) => {
      const raw = store.get(key) ?? null;
      if (raw === null) return null;
      if (type === "json") {
        try { return JSON.parse(raw) as unknown; } catch { return null; }
      }
      return raw;
    }),
    delete: vi.fn(async (key: string) => { store.delete(key); }),
    list: vi.fn(async () => ({ keys: [], list_complete: true, cursor: undefined })),
    getWithMetadata: vi.fn(async () => ({ value: null, metadata: null })),
  } as unknown as KVNamespace;
}

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    KV: makeMockKV(),
    HYPERDRIVE: {} as Hyperdrive,
    R2: {} as R2Bucket,
    JWT_SECRET: "test-jwt-secret-min-32-bytes-long!!",
    GOOGLE_WEB_CLIENT_ID: "test-google-client-id",
    R2_ACCESS_KEY_ID: "test-r2-key",
    R2_SECRET_ACCESS_KEY: "test-r2-secret",
    R2_ENDPOINT: "https://test.r2.cloudflarestorage.com",
    R2_BUCKET: "south-indian-wallpapers",
    R2_CDN_BASE_URL: "https://cdn.hsrutility.com",
    PHONEPE_MERCHANT_ID: "ARUL_MERCHANT",
    PHONEPE_CLIENT_ID: "test-client-id",
    PHONEPE_CLIENT_SECRET: "test-client-secret",
    PHONEPE_CLIENT_VERSION: "1",
    PHONEPE_WEBHOOK_USERNAME: "webhookuser",
    PHONEPE_WEBHOOK_PASSWORD: "webhookpass",
    PHONEPE_ENV: "SANDBOX",
    TRIAL_TOMBSTONE_SECRET: "test-tombstone-secret-32-bytes!!!!",
    CATALOG_BUILD_SECRET: "test-catalog-secret",
    ALLOWED_ORIGINS: "https://arul.hsrutility.com",
    ADMIN_USERNAME: "admin",
    ADMIN_PASSWORD_HASH: "pbkdf2$210000$c2FsdHNhbHQ=$aGFzaGhhc2g=",
    ADMIN_SESSION_SECRET: "test-admin-session-secret-min-32-bytes",
    ...overrides,
  };
}

/** Build a fake access-token response from PhonePe OAuth. */
function fakeOAuthResponse(expiresInSeconds = 3600): { access_token: string; token_type: string; expires_at: number; issued_at: number } {
  return {
    access_token: "test-access-token-xyz",
    token_type: "O-Bearer",
    issued_at: Math.floor(Date.now() / 1000),
    expires_at: Math.floor(Date.now() / 1000) + expiresInSeconds,
  };
}

// ── getAccessToken ────────────────────────────────────────────────────────────

describe("getAccessToken", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("fetches a new token when KV is empty and caches it", async () => {
    const env = makeEnv();
    const oauthData = fakeOAuthResponse(3600);

    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
      new Response(JSON.stringify(oauthData), { status: 200 }),
    ));

    const token = await getAccessToken(env);
    expect(token).toBe("test-access-token-xyz");
    expect(vi.mocked(fetch)).toHaveBeenCalledOnce();
    // Verify it called the sandbox OAuth URL
    const calledUrl = vi.mocked(fetch).mock.calls[0][0] as string;
    expect(calledUrl).toContain("api-preprod.phonepe.com");
    expect(calledUrl).toContain("/v1/oauth/token");
    // Verify it was cached in KV
    expect(env.KV.put).toHaveBeenCalled();
  });

  it("returns cached token without calling fetch", async () => {
    const futureExpiry = Math.floor(Date.now() / 1000) + 3600;
    const cachedEntry = JSON.stringify({ access_token: "cached-token", expires_at: futureExpiry });
    const kv = makeMockKV(new Map([["phonepe:oauth", cachedEntry]]));
    const env = makeEnv({ KV: kv });

    vi.stubGlobal("fetch", vi.fn());

    const token = await getAccessToken(env);
    expect(token).toBe("cached-token");
    expect(vi.mocked(fetch)).not.toHaveBeenCalled();
  });

  it("refreshes token when cached token is within 60s of expiry", async () => {
    // expires_at = now + 30s (within the 60s buffer)
    const soonExpiry = Math.floor(Date.now() / 1000) + 30;
    const cachedEntry = JSON.stringify({ access_token: "old-token", expires_at: soonExpiry });
    const kv = makeMockKV(new Map([["phonepe:oauth", cachedEntry]]));
    const env = makeEnv({ KV: kv });

    const oauthData = { ...fakeOAuthResponse(3600), access_token: "fresh-token" };
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
      new Response(JSON.stringify(oauthData), { status: 200 }),
    ));

    const token = await getAccessToken(env);
    expect(token).toBe("fresh-token");
    expect(vi.mocked(fetch)).toHaveBeenCalledOnce();
  });

  it("uses production identity-manager URL when PHONEPE_ENV=PRODUCTION", async () => {
    const env = makeEnv({ PHONEPE_ENV: "PRODUCTION" });
    const oauthData = fakeOAuthResponse();

    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
      new Response(JSON.stringify(oauthData), { status: 200 }),
    ));

    await getAccessToken(env);
    const calledUrl = vi.mocked(fetch).mock.calls[0][0] as string;
    expect(calledUrl).toBe("https://api.phonepe.com/apis/identity-manager/v1/oauth/token");
  });

  it("sends client_credentials grant with correct form fields", async () => {
    const env = makeEnv();
    const oauthData = fakeOAuthResponse();

    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
      new Response(JSON.stringify(oauthData), { status: 200 }),
    ));

    await getAccessToken(env);
    const call = vi.mocked(fetch).mock.calls[0];
    const init = call[1] as RequestInit;
    expect(init.method).toBe("POST");
    const body = init.body as string;
    expect(body).toContain("grant_type=client_credentials");
    expect(body).toContain("client_id=test-client-id");
    expect(body).toContain("client_secret=test-client-secret");
    expect(body).toContain("client_version=1");
  });

  it("throws on non-OK OAuth response", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(
      new Response("Unauthorized", { status: 401 }),
    ));
    await expect(getAccessToken(env)).rejects.toThrow("PhonePe OAuth error 401");
  });
});

// ── setupSubscription ─────────────────────────────────────────────────────────

describe("setupSubscription", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  function mockFetchWithOAuthThenSetup(setupResponse: object) {
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify(setupResponse), { status: 200 })),
    );
  }

  it("sends PENNY_DROP amount=200, maxAmount=19900, MONTHLY, UPI_MANDATE", async () => {
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({
      orderId: "PP_ORDER_123",
      state: "PENDING",
      token: "SDK_TOK",
      redirectUrl: "upi://pay?...",
    });

    await setupSubscription(env, {
      userId: "user-uuid-1",
      merchantSubscriptionId: "DKS_S_ABC_123",
      merchantOrderId: "DKS_O_ABC_123",
      redirectUrl: "https://api.hsrutility.com/payments/callback",
    });

    const setupCall = vi.mocked(fetch).mock.calls[1];
    const body = JSON.parse((setupCall[1] as RequestInit).body as string) as Record<string, unknown>;

    // Top-level amount MUST be 200 (PENNY_DROP)
    expect(body.amount).toBe(200);
    expect(body.merchantOrderId).toBe("DKS_O_ABC_123");

    const flow = body.paymentFlow as Record<string, unknown>;
    expect(flow.type).toBe("SUBSCRIPTION_CHECKOUT_SETUP");

    const merchantUrls = flow.merchantUrls as Record<string, unknown>;
    expect(merchantUrls.redirectUrl).toBe("https://api.hsrutility.com/payments/callback");

    const details = flow.subscriptionDetails as Record<string, unknown>;
    expect(details.subscriptionType).toBe("RECURRING");
    expect(details.merchantSubscriptionId).toBe("DKS_S_ABC_123");
    expect(details.authWorkflowType).toBe("PENNY_DROP");
    expect(details.amountType).toBe("FIXED");
    expect(details.maxAmount).toBe(19900); // ₹199 in paise
    expect(details.frequency).toBe("MONTHLY");
    expect(details.productType).toBe("UPI_MANDATE");
  });

  it("sends TRANSACTION with the real first-debit amount when upfrontAmountPaise is set", async () => {
    // One-trial-per-user: a trial-consumed user's new mandate is authorized via
    // a real ₹199 first debit, not the ₹2 PENNY_DROP.
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({ orderId: "PP_ORDER_UPFRONT", state: "PENDING", token: "T" });

    await setupSubscription(env, {
      userId: "user-uuid-1",
      merchantSubscriptionId: "DKS_S_ABC_123",
      merchantOrderId: "DKS_O_ABC_123",
      redirectUrl: "https://api.hsrutility.com/payments/callback",
      upfrontAmountPaise: 19900,
    });

    const setupCall = vi.mocked(fetch).mock.calls[1];
    const body = JSON.parse((setupCall[1] as RequestInit).body as string) as Record<string, unknown>;

    expect(body.amount).toBe(19900); // real first debit, charged during setup
    const flow = body.paymentFlow as Record<string, unknown>;
    const details = flow.subscriptionDetails as Record<string, unknown>;
    expect(details.authWorkflowType).toBe("TRANSACTION");
    expect(details.maxAmount).toBe(19900);
    expect(details.frequency).toBe("MONTHLY");
  });

  it("hits the Create SDK Order endpoint (/checkout/v2/sdk/order), not the web /pay", async () => {
    // The mobile SDK needs the SDK order token; /checkout/v2/pay only yields a
    // web-page token that the SDK rejects with PR004/401.
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({ orderId: "X", state: "PENDING", token: "T" });

    await setupSubscription(env, {
      userId: "u1",
      merchantSubscriptionId: "S1",
      merchantOrderId: "O1",
      redirectUrl: "https://example.com/cb",
    });

    const setupCall = vi.mocked(fetch).mock.calls[1];
    expect(setupCall[0]).toBe(
      "https://api-preprod.phonepe.com/apis/pg-sandbox/checkout/v2/sdk/order",
    );
  });

  it("sends O-Bearer Authorization header", async () => {
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({ orderId: "X", state: "PENDING", token: "T", redirectUrl: "u" });

    await setupSubscription(env, {
      userId: "u1",
      merchantSubscriptionId: "S1",
      merchantOrderId: "O1",
      redirectUrl: "https://example.com/cb",
    });

    const setupCall = vi.mocked(fetch).mock.calls[1];
    const headers = setupCall[1] as RequestInit & { headers: Record<string, string> };
    expect((headers.headers as Record<string, string>)["Authorization"]).toBe(
      "O-Bearer test-access-token-xyz",
    );
  });

  it("returns orderId, state, expireAt and the top-level SDK order token", async () => {
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({
      orderId: "PP_ORDER_999",
      state: "PENDING",
      token: "SDK_ORDER_TOKEN_ABC",
      expireAt: 1776145172971,
    });

    const result = await setupSubscription(env, {
      userId: "u1",
      merchantSubscriptionId: "S1",
      merchantOrderId: "O1",
      redirectUrl: "https://example.com/cb",
    });

    expect(result.orderId).toBe("PP_ORDER_999");
    expect(result.state).toBe("PENDING");
    expect(result.token).toBe("SDK_ORDER_TOKEN_ABC");
    expect(result.expireAt).toBe(1776145172971);
  });

  // A web-checkout token is NOT a valid SDK order token: handing one to the
  // Flutter SDK is exactly what makes it return 401 / PR004 "Unauthorized" on
  // device. The old code scraped ?token= out of redirectUrl as a "graceful"
  // fallback, which turned a diagnosable server error into a 200 carrying a
  // poisoned token. Never again — no SDK token is a hard failure.
  it("throws rather than scraping a web ?token= out of redirectUrl (PR004 guard)", async () => {
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({
      orderId: "X",
      state: "PENDING",
      redirectUrl: "https://mercury-t2.phonepe.com/transact/pgv3?token=WEB_TOK",
    });
    await expect(
      setupSubscription(env, {
        userId: "u1", merchantSubscriptionId: "S1", merchantOrderId: "O1", redirectUrl: "https://example.com/cb",
      }),
    ).rejects.toThrow(/no SDK token/i);
  });

  it("throws when the response carries no token at all", async () => {
    const env = makeEnv();
    mockFetchWithOAuthThenSetup({ orderId: "X", state: "PENDING", redirectUrl: "upi://pay?pa=abc" });
    await expect(
      setupSubscription(env, {
        userId: "u1", merchantSubscriptionId: "S1", merchantOrderId: "O1", redirectUrl: "https://example.com/cb",
      }),
    ).rejects.toThrow(/no SDK token/i);
  });

  it("throws on non-OK response", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response("Bad Request", { status: 400 })),
    );
    await expect(
      setupSubscription(env, { userId: "u", merchantSubscriptionId: "s", merchantOrderId: "o", redirectUrl: "r" }),
    ).rejects.toThrow("PhonePe setup error 400");
  });
});

// ── cancelSubscription ────────────────────────────────────────────────────────

describe("cancelSubscription", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("POSTs to /subscriptions/v2/{id}/cancel with O-Bearer and no X-MERCHANT-ID", async () => {
    // The documented /checkout/v2/subscriptions/{id}/cancel returns 401 for our
    // OAuth client; the working path is /subscriptions/v2/{id}/cancel, so that's
    // tried first. X-MERCHANT-ID is partner-only and must be omitted.
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(null, { status: 204 })),
    );

    await cancelSubscription(env, "DKS_S_ABC_123");

    const cancelCall = vi.mocked(fetch).mock.calls[1];
    expect(cancelCall[0]).toBe(
      "https://api-preprod.phonepe.com/apis/pg-sandbox/subscriptions/v2/DKS_S_ABC_123/cancel",
    );
    const init = cancelCall[1] as RequestInit & { headers: Record<string, string> };
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>)["Authorization"]).toBe("O-Bearer test-access-token-xyz");
    expect((init.headers as Record<string, string>)["X-MERCHANT-ID"]).toBeUndefined();
  });

  it("falls back to /checkout/v2 when /subscriptions/v2 cancel fails", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response("Unauthorized", { status: 401 })) // /subscriptions/v2
      .mockResolvedValueOnce(new Response(null, { status: 204 })),          // /checkout/v2 fallback
    );

    await cancelSubscription(env, "DKS_S_ABC_123");

    expect(vi.mocked(fetch).mock.calls[2][0]).toBe(
      "https://api-preprod.phonepe.com/apis/pg-sandbox/checkout/v2/subscriptions/DKS_S_ABC_123/cancel",
    );
  });

  it("throws only after BOTH cancel paths fail", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response("Not Found", { status: 404 }))   // /subscriptions/v2
      .mockResolvedValueOnce(new Response("Not Found", { status: 404 })),  // /checkout/v2 fallback
    );
    await expect(cancelSubscription(env, "MISSING")).rejects.toThrow(/cancel error.*404/);
    expect(vi.mocked(fetch).mock.calls.length).toBe(3);
  });
});

// ── notifyRedemption ──────────────────────────────────────────────────────────

describe("notifyRedemption", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("sends SUBSCRIPTION_REDEMPTION with STANDARD retry, autoDebit=false, amount=19900", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        orderId: "PP_NOTIFY_1",
        state: "NOTIFICATION_IN_PROGRESS",
        expireAt: Date.now() + 48 * 3600 * 1000,
      }), { status: 200 })),
    );

    await notifyRedemption(env, {
      merchantSubscriptionId: "DKS_S_ABC_123",
      merchantOrderId: "DKS_R_ABC_456",
      amountPaise: 19900,
    });

    const notifyCall = vi.mocked(fetch).mock.calls[1];
    expect(notifyCall[0]).toContain("/subscriptions/v2/notify");

    const body = JSON.parse((notifyCall[1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body.merchantOrderId).toBe("DKS_R_ABC_456");
    expect(body.amount).toBe(19900);

    const flow = body.paymentFlow as Record<string, unknown>;
    expect(flow.type).toBe("SUBSCRIPTION_REDEMPTION");
    expect(flow.merchantSubscriptionId).toBe("DKS_S_ABC_123");
    expect(flow.redemptionRetryStrategy).toBe("STANDARD");
    expect(flow.autoDebit).toBe(false);
  });

  it("returns orderId and state from PhonePe", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        orderId: "PP_NOTIFY_7",
        state: "NOTIFICATION_IN_PROGRESS",
        expireAt: 9999999999000,
      }), { status: 200 })),
    );

    const result = await notifyRedemption(env, {
      merchantSubscriptionId: "S1",
      merchantOrderId: "R1",
      amountPaise: 19900,
    });

    expect(result.orderId).toBe("PP_NOTIFY_7");
    expect(result.state).toBe("NOTIFICATION_IN_PROGRESS");
  });

  it("throws on non-OK response", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response("Forbidden", { status: 403 })),
    );
    await expect(
      notifyRedemption(env, { merchantSubscriptionId: "s", merchantOrderId: "o", amountPaise: 19900 }),
    ).rejects.toThrow("PhonePe notify error 403");
  });
});

// ── executeRedemption ─────────────────────────────────────────────────────────

describe("executeRedemption", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("POSTs to /subscriptions/v2/redeem with the merchantOrderId", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        state: "PENDING",
        transactionId: "TXN_001",
      }), { status: 200 })),
    );

    const result = await executeRedemption(env, "DKS_R_ORDER_1");

    const redeemCall = vi.mocked(fetch).mock.calls[1];
    expect(redeemCall[0]).toContain("/subscriptions/v2/redeem");
    const body = JSON.parse((redeemCall[1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body.merchantOrderId).toBe("DKS_R_ORDER_1");

    expect(result.state).toBe("PENDING");
    expect(result.transactionId).toBe("TXN_001");
  });

  it("returns COMPLETED state on successful debit", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        state: "COMPLETED",
        transactionId: "TXN_DONE",
      }), { status: 200 })),
    );

    const result = await executeRedemption(env, "ORDER_X");
    expect(result.state).toBe("COMPLETED");
    expect(result.transactionId).toBe("TXN_DONE");
  });
});

// ── initiateRefund ────────────────────────────────────────────────────────────

describe("initiateRefund", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("POSTs to /payments/v2/refund with correct fields", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        refundId: "REF_001",
        amount: 19900,
        state: "PENDING",
      }), { status: 200 })),
    );

    const result = await initiateRefund(env, "ORIG_ORDER_1", "DKS_REF_1", 19900);

    const refundCall = vi.mocked(fetch).mock.calls[1];
    expect(refundCall[0]).toContain("/payments/v2/refund");
    const body = JSON.parse((refundCall[1] as RequestInit).body as string) as Record<string, unknown>;
    expect(body.merchantRefundId).toBe("DKS_REF_1");
    expect(body.originalMerchantOrderId).toBe("ORIG_ORDER_1");
    expect(body.amount).toBe(19900);

    expect(result.refundId).toBe("REF_001");
    expect(result.amount).toBe(19900);
    expect(result.state).toBe("PENDING");
  });
});

// ── getSubscriptionStatus ─────────────────────────────────────────────────────

describe("getSubscriptionStatus", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("GETs /subscriptions/v2/{merchantSubscriptionId}/status?details=true", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        merchantSubscriptionId: "DKS_S_TESTID",
        subscriptionId: "PP_SUB_XYZ",
        state: "ACTIVE",
        authWorkflowType: "PENNY_DROP",
        amountType: "FIXED",
        maxAmount: "19900",
        frequency: "MONTHLY",
        expireAt: null,
      }), { status: 200 })),
    );

    const result = await getSubscriptionStatus(env, "DKS_S_TESTID");
    const statusCall = vi.mocked(fetch).mock.calls[1];
    expect(statusCall[0]).toContain("/subscriptions/v2/DKS_S_TESTID/status?details=true");
    expect(result.state).toBe("ACTIVE");
  });
});

// ── getOrderStatus ────────────────────────────────────────────────────────────

describe("getOrderStatus", () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it("GETs /subscriptions/v2/order/{merchantOrderId}/status?details=true", async () => {
    const env = makeEnv();
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify(fakeOAuthResponse()), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        state: "COMPLETED",
        orderId: "PP_ORD_1",
        merchantOrderId: "DKS_O_ORDER1",
        merchantId: "ARUL_MERCHANT",
        amount: 200,
        currency: "INR",
        expireAt: 9999999999000,
      }), { status: 200 })),
    );

    const result = await getOrderStatus(env, "DKS_O_ORDER1");
    const statusCall = vi.mocked(fetch).mock.calls[1];
    expect(statusCall[0]).toContain("/subscriptions/v2/order/DKS_O_ORDER1/status?details=true");
    expect(result.state).toBe("COMPLETED");
    expect(result.orderId).toBe("PP_ORD_1");
  });
});

// ── verifyCallbackAuth / verifyWebhookAuth ────────────────────────────────────

describe("verifyCallbackAuth", () => {
  it("returns true for SHA256(username:password) hex", async () => {
    const username = "webhookuser";
    const password = "webhookpass";
    const encoded = new TextEncoder().encode(`${username}:${password}`);
    const buf = await crypto.subtle.digest("SHA-256", encoded);
    const hex = Array.from(new Uint8Array(buf))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    const valid = await verifyCallbackAuth(hex, username, password);
    expect(valid).toBe(true);
  });

  it("returns false for wrong password", async () => {
    const valid = await verifyCallbackAuth("badsignature", "user", "wrongpassword");
    expect(valid).toBe(false);
  });

  it("returns false for empty auth header", async () => {
    const valid = await verifyCallbackAuth("", "user", "pass");
    expect(valid).toBe(false);
  });

  it("verifyWebhookAuth is an alias for verifyCallbackAuth", async () => {
    const username = "u";
    const password = "p";
    const encoded = new TextEncoder().encode(`${username}:${password}`);
    const buf = await crypto.subtle.digest("SHA-256", encoded);
    const hex = Array.from(new Uint8Array(buf))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    const valid = await verifyWebhookAuth(hex, username, password);
    expect(valid).toBe(true);
  });
});

// ── Merchant ID builders ──────────────────────────────────────────────────────

describe("buildMerchantSubscriptionId", () => {
  it("produces a string ≤ 63 characters", () => {
    const id = buildMerchantSubscriptionId("550e8400-e29b-41d4-a716-446655440000");
    expect(id.length).toBeLessThanOrEqual(63);
  });

  it("only contains [A-Za-z0-9_-]", () => {
    const id = buildMerchantSubscriptionId("550e8400-e29b-41d4-a716-446655440000");
    expect(id).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("produces different values for different user IDs", () => {
    const id1 = buildMerchantSubscriptionId("550e8400-e29b-41d4-a716-446655440000");
    const id2 = buildMerchantSubscriptionId("660f9511-f3ac-52e5-b827-557766551111");
    expect(id1).not.toBe(id2);
  });
});

describe("buildMerchantOrderId", () => {
  it("produces a string ≤ 63 characters", () => {
    const id = buildMerchantOrderId("550e8400-e29b-41d4-a716-446655440000");
    expect(id.length).toBeLessThanOrEqual(63);
  });

  it("only contains [A-Za-z0-9_-]", () => {
    const id = buildMerchantOrderId("550e8400-e29b-41d4-a716-446655440000");
    expect(id).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("uses the tag in the output", () => {
    const id = buildMerchantOrderId("abc123", "R");
    expect(id).toContain("_R_");
  });
});
