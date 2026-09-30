/**
 * Two PhonePe merchants, one Worker: every call must reach the merchant that OWNS the id it names.
 * lib/phonepe.ts runs for REAL against a fetch stub that tells the two merchants apart by their OAuth token, so a
 * call site that hands a legacy id to the hsr keys (or the reverse) fails here instead of parking live mandates
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Context } from "hono";
import type { Env } from "../src/env.js";
import { makeEnv, makeMockKV } from "./_ctx.js";
import { signAccessToken } from "../src/lib/jwt.js";

vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return { ...actual, getDb: (env: { _testSql: unknown }) => env._testSql };
});
vi.mock("../src/lib/referral.js", () => ({ grantReferralReward: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../src/lib/posthog.js", () => ({
  reportPostHogFirstConversion: vi.fn().mockResolvedValue(undefined),
  reportPostHogSubscriptionCancel: vi.fn().mockResolvedValue(undefined),
}));

import {
  PhonePeApiError,
  buildMerchantOrderId,
  buildMerchantSubscriptionId,
  cancelSubscription,
  executeRedemption,
  getAccessToken,
  getOrderStatus,
  getSubscriptionStatus,
  initiateRefund,
  merchantOf,
  notifyRedemption,
  revokeMandateTolerant,
  setupMerchant,
  setupSubscription,
  setupSubscriptionIntent,
} from "../src/lib/phonepe.js";
import {
  handleAbandon,
  handleCancel,
  handleInitiate,
  handleStatus,
  handleWebhook,
} from "../src/routes/payments.js";
import { handleRefund, handleRunRedemptions } from "../src/routes/internal.js";
import { handleDeleteAccount } from "../src/routes/me.js";
import { runAutopayNotify } from "../src/cron/autopay-notify.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";

const HSR_KEYS = {
  PHONEPE_HSR_MERCHANT_ID: "HSRUTILITYONLINE",
  PHONEPE_HSR_CLIENT_ID: "hsr-client",
  PHONEPE_HSR_CLIENT_SECRET: "hsr-secret",
  PHONEPE_HSR_CLIENT_VERSION: "1",
  PHONEPE_HSR_WEBHOOK_USERNAME: "hsruser",
  PHONEPE_HSR_WEBHOOK_PASSWORD: "hsrpass",
};

function dualEnv(overrides: Record<string, unknown> = {}): Env {
  return makeEnv({
    PHONEPE_MERCHANT_ID: "AUTOGRAMAPPSONLINE",
    PHONEPE_CLIENT_ID: "legacy-client",
    PHONEPE_CLIENT_SECRET: "legacy-secret",
    ...HSR_KEYS,
    ...overrides,
  });
}

interface PpCall {
  /** Which merchant's OAuth token authorised the call. */
  merchant: "legacy" | "hsr" | "none";
  path: string;
  body: Record<string, unknown> | null;
}

/** Answers every PhonePe endpoint; `answer` overrides one path. The OAuth token names the client that minted it. */
function fakePhonePe(answer: (path: string, method: string) => Response | undefined = () => undefined) {
  const calls: PpCall[] = [];
  const oauth: string[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const url = new URL(input);
      if (url.pathname.endsWith("/oauth/token")) {
        const clientId = new URLSearchParams(init.body as string).get("client_id") ?? "";
        oauth.push(clientId);
        return Response.json({
          access_token: `tok:${clientId}`,
          expires_at: Math.floor(Date.now() / 1000) + 3600,
        });
      }
      if (!url.hostname.includes("phonepe.com")) return new Response("ok");
      const auth = (init.headers as Record<string, string> | undefined)?.Authorization ?? "";
      const merchant =
        auth === "O-Bearer tok:legacy-client"
          ? "legacy"
          : auth === "O-Bearer tok:hsr-client"
            ? "hsr"
            : "none";
      const body = typeof init.body === "string" ? (JSON.parse(init.body) as Record<string, unknown>) : null;
      calls.push({ merchant, path: decodeURIComponent(url.pathname), body });
      const method = init.method ?? "GET";
      const custom = answer(url.pathname, method);
      if (custom) return custom;
      if (url.pathname.endsWith("/checkout/v2/sdk/order")) {
        return Response.json({ orderId: "OMO_SDK", state: "PENDING", token: "SDKTOKEN" });
      }
      if (url.pathname.endsWith("/subscriptions/v2/setup")) {
        return Response.json({ orderId: "OMO_INT", state: "PENDING", intentUrl: "upi://mandate?pa=x" });
      }
      if (url.pathname.endsWith("/cancel")) return new Response(null, { status: 204 });
      if (url.pathname.endsWith("/subscriptions/v2/notify")) {
        return Response.json({ orderId: "OMO_N", state: "NOTIFIED", expireAt: Date.now() + 86_400_000 });
      }
      if (url.pathname.endsWith("/subscriptions/v2/redeem")) {
        return Response.json({ state: "PENDING", transactionId: "TXN" });
      }
      if (url.pathname.includes("/subscriptions/v2/order/")) {
        return Response.json({ state: "PENDING", orderId: "OMO_O", expireAt: Date.now() + 86_400_000 });
      }
      if (url.pathname.endsWith("/status")) return Response.json({ state: "ACTIVE" });
      if (url.pathname.endsWith("/payments/v2/refund")) {
        return Response.json({ refundId: "OMR", amount: 19900, state: "PENDING" });
      }
      return new Response("unexpected", { status: 500 });
    }),
  );
  return { calls, oauth };
}

/** Every call names at least one DKS_ id, and each id it names belongs to the merchant whose token went out. */
function expectEachCallAtItsOwnMerchant(calls: PpCall[]) {
  expect(calls.length).toBeGreaterThan(0);
  for (const call of calls) {
    const ids = `${call.path} ${JSON.stringify(call.body ?? {})}`.match(/DKS_[A-Za-z0-9_-]+/g) ?? [];
    expect(ids.length, call.path).toBeGreaterThan(0);
    for (const id of ids) expect(call.merchant, `${call.path} named ${id}`).toBe(merchantOf(id));
  }
}

const at = (calls: PpCall[], merchant: string) => calls.filter((c) => c.merchant === merchant);

/** Routes one result set per statement by its text; unmatched statements answer []. */
function routedSql(route: (text: string) => unknown[] | undefined) {
  const texts: string[] = [];
  const fn = vi.fn((strings: TemplateStringsArray, ..._vals: unknown[]) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    texts.push(text);
    return Promise.resolve(route(text) ?? []);
  });
  const sql = Object.assign(fn, {
    end: vi.fn().mockResolvedValue(undefined),
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(fn)),
  });
  return { sql, texts };
}

/** A route context whose waitUntil work can be awaited -> background revokes are part of what is asserted. */
function ctx(env: Env, opts: { token?: string; auth?: string; body?: unknown } = {}) {
  const pending: Promise<unknown>[] = [];
  const c = {
    env,
    req: {
      url: "https://arul-api.hsrutility.com/payments/x",
      header: (name: string) =>
        name.toLowerCase() === "authorization"
          ? (opts.auth ?? (opts.token ? `Bearer ${opts.token}` : undefined))
          : undefined,
      raw: {},
      json: () => Promise.resolve(opts.body ?? {}),
      text: () => Promise.resolve(JSON.stringify(opts.body ?? {})),
    },
    json: (b: unknown, status = 200) => Response.json(b, { status }),
    executionCtx: { waitUntil: (p: Promise<unknown>) => pending.push(p) },
  } as unknown as Context<{ Bindings: Env }>;
  return { c, settle: () => Promise.all(pending) };
}

async function sha(u: string, p: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${u}:${p}`));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("merchantOf and the marked ids", () => {
  it.each([
    ["DKS_S_ABCD1234_MUL7AO1V", "legacy"],
    ["DKS_S_ABCD1234_MUL7AO1V_1F07", "legacy"],
    ["DKS_R_ABCD1234_MUL7AO1V_1F07", "legacy"],
    ["DKS_REF_DKS_R_AB_MUL7AO1V_1F07", "legacy"],
    ["DKS_O_ABCD1234_MUL7AO1V_1F07", "legacy"],
    ["DKS_HS_ABCD1234_MUL7AO1V", "hsr"],
    ["DKS_HR_ABCD1234_MUL7AO1V_1F07", "hsr"],
    ["DKS_HREF_DKS_HR_A_MUL7AO1V_1F07", "hsr"],
  ])("%s -> %s", (id, merchant) => {
    expect(merchantOf(id)).toBe(merchant);
  });

  it("mints unmarked legacy ids and H-marked hsr ids for every tag, within PhonePe's 63-char cap", () => {
    expect(buildMerchantSubscriptionId(USER_ID, "legacy")).toMatch(/^DKS_S_550E8400_[0-9A-Z]+$/);
    expect(buildMerchantSubscriptionId(USER_ID, "hsr")).toMatch(/^DKS_HS_550E8400_[0-9A-Z]+$/);
    for (const tag of ["S", "R", "REF", "O"]) {
      const legacy = buildMerchantOrderId(USER_ID, tag, "legacy");
      const hsr = buildMerchantOrderId(USER_ID, tag, "hsr");
      expect(legacy.startsWith(`DKS_${tag}_`)).toBe(true);
      expect(hsr.startsWith(`DKS_H${tag}_`)).toBe(true);
      expect(merchantOf(legacy)).toBe("legacy");
      expect(merchantOf(hsr)).toBe("hsr");
      expect(hsr.length).toBeLessThanOrEqual(63);
      expect(hsr).toMatch(/^[A-Za-z0-9_-]+$/);
    }
  });
});

describe("setupMerchant — where NEW setups go", () => {
  it.each([
    [undefined, false, "legacy"],
    ["legacy", true, "legacy"],
    ["typo", true, "legacy"],
    ["hsr", false, "hsr"],
    [" HSR ", false, "hsr"],
    ["hsr-internal", false, "legacy"],
    ["hsr-internal", true, "hsr"],
  ])("PHONEPE_SETUP_MERCHANT=%s internal=%s -> %s", (mode, internal, want) => {
    expect(setupMerchant(dualEnv({ PHONEPE_SETUP_MERCHANT: mode }), internal)).toBe(want);
  });

  it("stays on legacy when hsr is switched on but its keys are missing", () => {
    const env = dualEnv({ PHONEPE_SETUP_MERCHANT: "hsr", PHONEPE_HSR_CLIENT_SECRET: undefined });
    expect(setupMerchant(env, true)).toBe("legacy");
  });
});

describe("lib/phonepe.ts — each call uses the keys of the merchant its id names", () => {
  const legacy = { sub: "DKS_S_AAAA1111_X1", setup: "DKS_S_AAAA1111_X1_0001", red: "DKS_R_AAAA1111_X2_0002" };
  const hsr = { sub: "DKS_HS_BBBB2222_Y1", setup: "DKS_HS_BBBB2222_Y1_0001", red: "DKS_HR_BBBB2222_Y2_0002" };

  it.each([
    ["legacy", legacy],
    ["hsr", hsr],
  ])("%s ids go to the %s merchant on every endpoint", async (merchant, ids) => {
    const { calls } = fakePhonePe();
    const env = dualEnv();
    await setupSubscription(env, {
      userId: USER_ID,
      merchantSubscriptionId: ids.sub,
      merchantOrderId: ids.setup,
      redirectUrl: "https://arul-api.hsrutility.com/payments/callback",
      maxAmountPaise: 19900,
    });
    await setupSubscriptionIntent(env, {
      merchantSubscriptionId: ids.sub,
      merchantOrderId: ids.setup,
      targetApp: "com.phonepe.app",
      maxAmountPaise: 19900,
    });
    await cancelSubscription(env, ids.sub);
    await revokeMandateTolerant(env, ids.sub);
    await notifyRedemption(env, {
      merchantSubscriptionId: ids.sub,
      merchantOrderId: ids.red,
      amountPaise: 19900,
    });
    await executeRedemption(env, ids.red);
    await getSubscriptionStatus(env, ids.sub);
    await getOrderStatus(env, ids.red);
    await initiateRefund(env, ids.red, buildMerchantOrderId(ids.red, "REF", merchantOf(ids.red)), 19900);

    expect(calls.length).toBe(9);
    expect(calls.every((c) => c.merchant === merchant)).toBe(true);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it("caches one OAuth token per merchant, legacy under its old key", async () => {
    const { oauth } = fakePhonePe();
    const env = dualEnv();
    await getSubscriptionStatus(env, legacy.sub);
    await getSubscriptionStatus(env, hsr.sub);
    await getSubscriptionStatus(env, legacy.sub);
    await getSubscriptionStatus(env, hsr.sub);

    expect(oauth).toEqual(["legacy-client", "hsr-client"]);
    expect(await env.KV.get("phonepe:oauth", "json")).toMatchObject({ access_token: "tok:legacy-client" });
    expect(await env.KV.get("phonepe:oauth:hsr", "json")).toMatchObject({ access_token: "tok:hsr-client" });
  });

  it("never sends a cached legacy token on an hsr call", async () => {
    const kv = makeMockKV(
      new Map([
        [
          "phonepe:oauth",
          JSON.stringify({
            access_token: "tok:legacy-client",
            expires_at: Math.floor(Date.now() / 1000) + 3600,
          }),
        ],
      ]),
    );
    const { calls, oauth } = fakePhonePe();
    await getSubscriptionStatus(dualEnv({ KV: kv }), hsr.sub);
    expect(oauth).toEqual(["hsr-client"]);
    expect(calls[0].merchant).toBe("hsr");
  });

  it("refuses ids from two merchants in one call without calling PhonePe, as a transient error", async () => {
    const { calls, oauth } = fakePhonePe();
    const err = await notifyRedemption(dualEnv(), {
      merchantSubscriptionId: hsr.sub,
      merchantOrderId: legacy.red,
      amountPaise: 19900,
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(Error);
    expect(err).not.toBeInstanceOf(PhonePeApiError);
    expect(calls.length + oauth.length).toBe(0);
  });

  it("an hsr id on a Worker without hsr keys fails transient and never reaches PhonePe", async () => {
    const { calls, oauth } = fakePhonePe();
    const env = dualEnv({ PHONEPE_HSR_CLIENT_ID: undefined });
    const err = await getSubscriptionStatus(env, hsr.sub).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(Error);
    expect(err).not.toBeInstanceOf(PhonePeApiError);
    expect(await revokeMandateTolerant(env, hsr.sub)).toBe(false);
    expect(calls.length + oauth.length).toBe(0);
  });

  it("getAccessToken asks the named merchant's client", async () => {
    const { oauth } = fakePhonePe();
    await getAccessToken(dualEnv(), "hsr");
    expect(oauth).toEqual(["hsr-client"]);
  });
});

describe("POST /payments/initiate — the setup merchant", () => {
  let token: string;
  beforeEach(async () => {
    token = await signAccessToken(USER_ID, makeEnv().JWT_SECRET);
  });

  async function initiate(env: Env, body: Record<string, unknown>, prior: unknown[] = [], internal = false) {
    const { sql } = routedSql((t) => {
      if (t.startsWith("SELECT is_internal")) return [{ is_internal: internal }];
      if (t.startsWith("SELECT s.trial_end")) return prior;
      return undefined;
    });
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const { c, settle } = ctx(env, { token, body });
    const res = await handleInitiate(c);
    await settle();
    return (await res.json()) as Record<string, unknown>;
  }

  it("defaults to legacy: unmarked ids, legacy keys, the legacy merchant id for the SDK", async () => {
    const { calls } = fakePhonePe();
    const out = await initiate(dualEnv(), { plan: "monthly" });
    expect(String(out.merchantSubscriptionId)).toMatch(/^DKS_S_/);
    expect(out.merchantId).toBe("AUTOGRAMAPPSONLINE");
    expect(at(calls, "hsr")).toEqual([]);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it("switched to hsr: marked ids, hsr keys, and the hsr merchant id for the SDK fallback", async () => {
    const { calls } = fakePhonePe((path) =>
      path.endsWith("/subscriptions/v2/setup") ? new Response("down", { status: 500 }) : undefined,
    );
    const out = await initiate(dualEnv({ PHONEPE_SETUP_MERCHANT: "hsr" }), {
      plan: "monthly",
      targetApp: "com.phonepe.app",
    });
    expect(String(out.merchantSubscriptionId)).toMatch(/^DKS_HS_/);
    expect(String(out.merchantOrderId)).toMatch(/^DKS_HS_/);
    expect(out.merchantId).toBe("HSRUTILITYONLINE");
    expect(at(calls, "legacy")).toEqual([]);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it("hsr-internal sends only is_internal accounts to hsr", async () => {
    const env = dualEnv({ PHONEPE_SETUP_MERCHANT: "hsr-internal" });
    fakePhonePe();
    const inside = await initiate(env, { plan: "monthly", targetApp: "com.phonepe.app" }, [], true);
    fakePhonePe();
    const outside = await initiate(env, { plan: "monthly", targetApp: "com.phonepe.app" }, [], false);
    expect(String(inside.merchantSubscriptionId)).toMatch(/^DKS_HS_/);
    expect(String(outside.merchantSubscriptionId)).toMatch(/^DKS_S_/);
  });

  it("a new hsr setup over an expired legacy row revokes the old mandate at LEGACY", async () => {
    const { calls } = fakePhonePe();
    await initiate(
      dualEnv({ PHONEPE_SETUP_MERCHANT: "hsr" }),
      { plan: "monthly", targetApp: "com.phonepe.app" },
      [{ status: "expired", merchant_subscription_id: "DKS_S_OLD00000_Z", trial_end: new Date(0) }],
    );
    expect(at(calls, "legacy").map((c) => c.path)).toContain(
      "/apis/pg-sandbox/subscriptions/v2/DKS_S_OLD00000_Z/cancel",
    );
    expectEachCallAtItsOwnMerchant(calls);
  });
});

describe("POST /payments/webhook — two SHA pairs, one merchant per id", () => {
  const setupEvent = (msid: string, orderId: string, merchantId: string) => ({
    event: "subscription.setup.order.completed",
    payload: {
      merchantId,
      merchantOrderId: orderId,
      orderId: `OMO_${orderId}`,
      state: "COMPLETED",
      amount: 200,
      paymentFlow: { type: "SUBSCRIPTION_SETUP", merchantSubscriptionId: msid, subscriptionId: "OMS1" },
    },
  });

  async function deliver(env: Env, auth: string, body: unknown, route: (t: string) => unknown[] | undefined) {
    const { sql, texts } = routedSql(route);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const { c, settle } = ctx(env, { auth, body });
    const res = await handleWebhook(c);
    await settle();
    return { res, texts };
  }

  // The ordinary grant (the offer switch runs first and matches nothing for these setups)
  const grants = (t: string) =>
    t.includes("AND NOT s.offer_switch") ? [{ user_id: USER_ID, status: "trialing" }] : undefined;

  it.each([
    ["legacy", "u", "p"],
    ["hsr", "hsruser", "hsrpass"],
  ])("accepts the %s pair", async (_m, u, p) => {
    fakePhonePe();
    const { res, texts } = await deliver(
      dualEnv(),
      await sha(u, p),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_HS_BBBB2222_Y1_0001", "HSRUTILITYONLINE"),
      grants,
    );
    expect(res.status).toBe(200);
    expect(texts.some((t) => t.includes("AND s.status = 'pending'"))).toBe(true);
  });

  it("rejects a delivery that matches neither pair", async () => {
    const { res } = await deliver(
      dualEnv(),
      await sha("hsruser", "wrong"),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_HS_BBBB2222_Y1_0001", "HSRUTILITYONLINE"),
      grants,
    );
    expect(res.status).toBe(401);
  });

  it("refuses an order event whose merchantId is the OTHER merchant's, without marking it", async () => {
    const env = dualEnv();
    const { res, texts } = await deliver(
      env,
      await sha("hsruser", "hsrpass"),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_HS_BBBB2222_Y1_0001", "AUTOGRAMAPPSONLINE"),
      grants,
    );
    expect(res.status).toBe(200);
    expect(texts.some((t) => t.startsWith("UPDATE"))).toBe(false);
    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("refuses an event whose order id and mandate id name different merchants", async () => {
    const env = dualEnv();
    const { texts } = await deliver(
      env,
      await sha("hsruser", "hsrpass"),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_S_AAAA1111_X1_0001", "HSRUTILITYONLINE"),
      grants,
    );
    expect(texts.some((t) => t.startsWith("UPDATE"))).toBe(false);
    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("processes an unrecognised merchantId by the id rather than dropping a real grant", async () => {
    fakePhonePe();
    const { texts } = await deliver(
      dualEnv(),
      await sha("hsruser", "hsrpass"),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_HS_BBBB2222_Y1_0001", "SOMEOTHERMID"),
      grants,
    );
    expect(texts.some((t) => t.includes("AND s.status = 'pending'"))).toBe(true);
  });

  it("an hsr grant revokes the parked LEGACY mandate at legacy", async () => {
    const { calls } = fakePhonePe();
    await deliver(
      dualEnv(),
      await sha("hsruser", "hsrpass"),
      setupEvent("DKS_HS_BBBB2222_Y1", "DKS_HS_BBBB2222_Y1_0001", "HSRUTILITYONLINE"),
      (t) =>
        t.includes("AND NOT s.offer_switch")
          ? [{ user_id: USER_ID, status: "trialing", stale_mandate_id: "DKS_S_AAAA1111_X1" }]
          : undefined,
    );
    expect(calls.map((c) => [c.merchant, c.path])).toEqual([
      ["legacy", "/apis/pg-sandbox/subscriptions/v2/DKS_S_AAAA1111_X1/cancel"],
    ]);
  });

  it("a debit on the parked legacy mandate retires the unapproved hsr one at hsr", async () => {
    const { calls } = fakePhonePe();
    await deliver(
      dualEnv(),
      await sha("u", "p"),
      {
        event: "subscription.redemption.order.completed",
        payload: {
          merchantId: "AUTOGRAMAPPSONLINE",
          merchantOrderId: "DKS_R_AAAA1111_X2_0002",
          orderId: "OMO_R1",
          state: "COMPLETED",
          amount: 19900,
          paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: "DKS_S_AAAA1111_X1" },
        },
      },
      (t) =>
        t.includes("SET status = 'active', merchant_subscription_id =")
          ? [{ user_id: USER_ID, prior_status: "active", prior_mandate_id: "DKS_HS_BBBB2222_Y1" }]
          : undefined,
    );
    expect(calls.map((c) => [c.merchant, c.path])).toEqual([
      ["hsr", "/apis/pg-sandbox/subscriptions/v2/DKS_HS_BBBB2222_Y1/cancel"],
    ]);
  });
});

describe("status, cancel, abandon — reads and revokes by the id they hold", () => {
  let token: string;
  beforeEach(async () => {
    token = await signAccessToken(USER_ID, makeEnv().JWT_SECRET);
  });

  async function call(
    handler: (c: Context<{ Bindings: Env }>) => Promise<Response>,
    route: (t: string) => unknown[] | undefined,
    body: unknown = {},
  ) {
    const env = dualEnv();
    const { sql } = routedSql(route);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const { c, settle } = ctx(env, { token, body });
    const res = await handler(c);
    await settle();
    return res;
  }

  it("status reads a pending hsr setup at hsr", async () => {
    const { calls } = fakePhonePe();
    await call(handleStatus, (t) =>
      t.startsWith("SELECT id, user_id")
        ? [
            {
              id: "row",
              status: "pending",
              merchant_subscription_id: "DKS_HS_BBBB2222_Y1",
              merchant_order_id: "DKS_HS_BBBB2222_Y1_0001",
            },
          ]
        : undefined,
    );
    expect(at(calls, "hsr").length).toBe(1);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it("status reads a trialing legacy mandate and its old redemption at legacy", async () => {
    const { calls } = fakePhonePe();
    await call(handleStatus, (t) =>
      t.startsWith("SELECT id, user_id")
        ? [
            {
              id: "row",
              status: "cancelled",
              merchant_subscription_id: "DKS_S_AAAA1111_X1",
              merchant_order_id: "DKS_S_AAAA1111_X1_0001",
              redemption_order_id: "DKS_R_AAAA1111_X2_0002",
              trial_end: new Date(Date.now() - 86_400_000),
              current_period_end: new Date(Date.now() - 86_400_000),
            },
          ]
        : undefined,
    );
    expect(calls.map((c) => c.merchant)).toEqual(["legacy"]);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it("cancel revokes a live hsr mandate at hsr and the parked legacy one at legacy", async () => {
    const { calls } = fakePhonePe();
    const res = await call(handleCancel, (t) =>
      t.startsWith("SELECT merchant_subscription_id")
        ? [
            {
              status: "trialing",
              merchant_subscription_id: "DKS_HS_BBBB2222_Y1",
              superseded_mandate_id: "DKS_S_AAAA1111_X1",
            },
          ]
        : undefined,
    );
    expect(res.status).toBe(200);
    expect(calls.map((c) => [c.merchant, c.path.split("/").at(-2)])).toEqual([
      ["hsr", "DKS_HS_BBBB2222_Y1"],
      ["legacy", "DKS_S_AAAA1111_X1"],
    ]);
  });

  it("abandon reads and revokes an hsr setup at hsr", async () => {
    const { calls } = fakePhonePe();
    await call(
      handleAbandon,
      (t) => {
        if (t.startsWith("SELECT status, merchant_subscription_id")) {
          return [{ status: "pending", merchant_subscription_id: "DKS_HS_BBBB2222_Y1" }];
        }
        if (t.includes("AS released_mandate_id")) return [{ released_mandate_id: "DKS_HS_BBBB2222_Y1" }];
        return undefined;
      },
      { merchantOrderId: "DKS_HS_BBBB2222_Y1_0001" },
    );
    expect(calls.length).toBe(2);
    expect(at(calls, "legacy")).toEqual([]);
    expectEachCallAtItsOwnMerchant(calls);
  });
});

describe("DELETE /me — each mandate revoked at its own merchant", () => {
  it.each([
    ["DKS_S_AAAA1111_X1", "DKS_HS_BBBB2222_Y1"],
    ["DKS_HS_BBBB2222_Y1", "DKS_S_AAAA1111_X1"],
  ])("live %s + parked %s", async (live, parked) => {
    const { calls } = fakePhonePe();
    const env = dualEnv();
    const { sql } = routedSql((t) =>
      t.startsWith("SELECT u.google_sub")
        ? [
            {
              google_sub: "g",
              status: "pending",
              merchant_subscription_id: live,
              superseded_mandate_id: parked,
              trial_end: null,
            },
          ]
        : undefined,
    );
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const { c } = ctx(env, { token: await signAccessToken(USER_ID, env.JWT_SECRET) });
    const res = await handleDeleteAccount(c);
    expect(res.status).toBe(200);
    expect(calls.map((x) => x.path.split("/").at(-2))).toEqual([live, parked]);
    expectEachCallAtItsOwnMerchant(calls);
  });
});

describe("autopay cron — both merchants' rows in one run", () => {
  const HOUR = 3_600_000;
  const due = (id: string, msid: string, order: string | null, extra: Record<string, unknown> = {}) => ({
    id,
    user_id: USER_ID,
    status: "trialing",
    merchant_subscription_id: msid,
    redemption_order_id: order,
    retry_count: 0,
    next_debit_at: new Date(Date.now() - 3 * HOUR).toISOString(),
    current_period_end: new Date(Date.now() - 3 * HOUR).toISOString(),
    notified_at: new Date(Date.now() - 25 * HOUR).toISOString(),
    ...extra,
  });

  function cronSql(passA: unknown[], passB: unknown[], passD: unknown[] = []) {
    return routedSql((t) => {
      if (t.includes("min(next_debit_at)")) return [{ soonest: null, in_flight: 0, paused_rechecks: 0 }];
      if (t.includes("notified_at IS NULL")) return passA;
      if (t.includes("notified_at IS NOT NULL")) return passB;
      if (t.includes("FROM subscriptions WHERE status = 'paused'")) return passD;
      return undefined;
    });
  }

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-09-28T10:05:00Z"));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("notifies, executes and rechecks each row at its own merchant, minting redemptions under its marker", async () => {
    // NOTIFIED is non-terminal and not PENDING -> Pass B goes on to redeem, so every call type is exercised
    const { calls } = fakePhonePe((path) =>
      path.includes("/subscriptions/v2/order/")
        ? Response.json({ state: "NOTIFIED", orderId: "OMO_O", expireAt: Date.now() + 86_400_000 })
        : undefined,
    );
    const env = dualEnv();
    const { sql, texts } = cronSql(
      [due("a1", "DKS_S_AAAA1111_X1", null), due("a2", "DKS_HS_BBBB2222_Y1", null)],
      [
        due("b1", "DKS_S_CCCC3333_Z1", "DKS_R_CCCC3333_Z2_0001"),
        due("b2", "DKS_HS_DDDD4444_W1", "DKS_HR_DDDD4444_W2_0001"),
      ],
      [
        { id: "d1", merchant_subscription_id: "DKS_S_EEEE5555_V1" },
        { id: "d2", merchant_subscription_id: "DKS_HS_FFFF6666_U1" },
      ],
    );
    (env as unknown as { _testSql: unknown })._testSql = sql;

    await runAutopayNotify(env);

    const notifies = calls.filter((c) => c.path.endsWith("/notify"));
    expect(
      notifies.map((c) => [c.merchant, String(c.body?.merchantOrderId).match(/^DKS_H?R_/)?.[0]]),
    ).toEqual([
      ["legacy", "DKS_R_"],
      ["hsr", "DKS_HR_"],
    ]);
    expect(calls.filter((c) => c.path.endsWith("/redeem")).map((c) => c.merchant)).toEqual(["legacy", "hsr"]);
    expect(at(calls, "none")).toEqual([]);
    expectEachCallAtItsOwnMerchant(calls);
    expect(texts.some((t) => t.includes("SET status = ?"))).toBe(false);
  });

  it("never parks an hsr row on a Worker without hsr keys, and still bills the legacy row", async () => {
    const { calls } = fakePhonePe();
    const env = dualEnv({ PHONEPE_HSR_CLIENT_SECRET: undefined });
    const { sql, texts } = cronSql(
      [due("a1", "DKS_S_AAAA1111_X1", null), due("a2", "DKS_HS_BBBB2222_Y1", null)],
      [],
    );
    (env as unknown as { _testSql: unknown })._testSql = sql;

    await runAutopayNotify(env);

    expect(calls.map((c) => c.merchant)).toEqual(["legacy", "legacy"]);
    expect(texts.some((t) => t.includes("SET status = ?"))).toBe(false);
  });

  it("a legacy mandate PhonePe no longer knows is still parked cancelled (legacy behaviour unchanged)", async () => {
    fakePhonePe((path) =>
      path.endsWith("/status")
        ? new Response('{"code":"SUBSCRIPTION_NOT_FOUND"}', { status: 400 })
        : undefined,
    );
    const env = dualEnv();
    const { sql, texts } = cronSql([due("a1", "DKS_S_AAAA1111_X1", null)], []);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    await runAutopayNotify(env);

    expect(texts.some((t) => t.includes("SET status = ?"))).toBe(true);
  });
});

describe("/internal — money-moving operator routes inherit the merchant", () => {
  function opsCtx(env: Env, body: unknown) {
    return ctx(env, { auth: `Bearer ${env.OPS_SECRET}`, body });
  }

  it("run-redemptions mints an hsr redemption for an hsr mandate and bills it at hsr", async () => {
    const { calls } = fakePhonePe();
    const env = dualEnv();
    const { sql } = routedSql((t) =>
      t.startsWith("SELECT id, user_id, merchant_subscription_id")
        ? [
            {
              id: "r",
              user_id: USER_ID,
              merchant_subscription_id: "DKS_HS_BBBB2222_Y1",
              redemption_order_id: null,
            },
          ]
        : undefined,
    );
    (env as unknown as { _testSql: unknown })._testSql = sql;

    await handleRunRedemptions(opsCtx(env, { merchantSubscriptionId: "DKS_HS_BBBB2222_Y1" }).c);

    expect(calls.map((c) => c.merchant)).toEqual(["hsr", "hsr", "hsr"]);
    expect(String(calls.find((c) => c.path.endsWith("/notify"))?.body?.merchantOrderId)).toMatch(/^DKS_HR_/);
    expectEachCallAtItsOwnMerchant(calls);
  });

  it.each([
    ["DKS_R_AAAA1111_X2_0002", "legacy", /^DKS_REF_/],
    ["DKS_HR_BBBB2222_Y2_0002", "hsr", /^DKS_HREF_/],
  ])("refund of %s goes to %s with a refund id under the same marker", async (order, merchant, refundRe) => {
    const { calls } = fakePhonePe();
    const env = dualEnv();
    const { sql } = routedSql((t) =>
      t.startsWith("SELECT user_id, price_paise FROM subscriptions")
        ? [{ user_id: USER_ID, price_paise: 19900 }]
        : undefined,
    );
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await handleRefund(opsCtx(env, { originalMerchantOrderId: order }).c);

    expect(res.status).toBe(200);
    expect(calls.map((c) => c.merchant)).toEqual([merchant]);
    expect(String(calls[0].body?.merchantRefundId)).toMatch(refundRe);
  });
});
