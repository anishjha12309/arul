/**
 * The ₹99 cancel-save switch end to end with PHONEPE_SETUP_MERCHANT=hsr, from a legacy ₹199 (DKS_S_…) and from an
 * hsr ₹199 (DKS_HS_…): park, grant, first ₹99 debit, release, late approval, cancel mid-switch. Each step feeds the
 * row the previous one leaves; the invariant under test is that no PhonePe call ever names two merchants' ids
 */

import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { Context } from "hono";
import type { Env } from "../src/env.js";
import { makeEnv } from "./_ctx.js";

vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return { ...actual, getDb: (env: { _testSql: unknown }) => env._testSql };
});
vi.mock("../src/lib/referral.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/lib/referral.js")>()),
  grantReferralReward: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("../src/lib/posthog.js", () => ({
  reportPostHogFirstConversion: vi.fn().mockResolvedValue(undefined),
  reportPostHogSubscriptionCancel: vi.fn().mockResolvedValue(undefined),
}));

import { runAutopayNotify } from "../src/cron/autopay-notify.js";
import { runHourlySweeps } from "../src/cron/autopay-sweeps.js";
import { signAccessToken } from "../src/lib/jwt.js";
import { merchantOf } from "../src/lib/phonepe.js";
import { reportPostHogFirstConversion } from "../src/lib/posthog.js";
import { handleMe } from "../src/routes/me.js";
import {
  handleAbandon,
  handleCancel,
  handleInitiate,
  handleStatus,
  handleWebhook,
} from "../src/routes/payments.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const LEGACY_199 = "DKS_S_550E8400_MFX1K2A0";
const HSR_199 = "DKS_HS_550E8400_MFX1K2A0";
const HSR_99 = "DKS_HS_550E8400_MG2B7Q10";
const HSR_99_ORDER = "DKS_HS_550E8400_MG2B7Q10_1A2B";
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const ago = (ms: number) => new Date(Date.now() - ms);
const ahead = (ms: number) => new Date(Date.now() + ms);

type J = Record<string, unknown>;

interface Stmt {
  text: string;
  values: unknown[];
}
type Answer = unknown[] | Error | undefined;
type Route = (text: string, values: unknown[]) => Answer;

function routedSql(route: Route = () => undefined) {
  const stmts: Stmt[] = [];
  const tag = (strings: TemplateStringsArray, ...vals: unknown[]) => {
    let text = strings[0];
    const values: unknown[] = [];
    vals.forEach((v, k) => {
      const frag = v as { sqlFragment?: boolean; text?: string; values?: unknown[] } | null;
      if (frag !== null && typeof frag === "object" && frag.sqlFragment === true) {
        text += `(${frag.text})`;
        values.push(...(frag.values ?? []));
      } else {
        text += "?";
        values.push(v);
      }
      text += strings[k + 1];
    });
    const stmt: Stmt = { text: text.replace(/\s+/g, " ").trim(), values };
    let run: Promise<unknown[]> | null = null;
    const exec = (): Promise<unknown[]> => {
      if (!run) {
        stmts.push(stmt);
        const answer = route(stmt.text, stmt.values);
        run = answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer ?? []);
      }
      return run;
    };
    return {
      sqlFragment: true,
      text: stmt.text,
      values: stmt.values,
      // biome-ignore lint/suspicious/noThenProperty: postgres.js queries are lazy thenables; the mock must be one too
      then: (ok?: (v: unknown[]) => unknown, bad?: (e: unknown) => unknown) => exec().then(ok, bad),
      catch: (bad: (e: unknown) => unknown) => exec().catch(bad),
    };
  };
  const sql = Object.assign(tag, {
    end: vi.fn(async () => undefined),
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(tag)),
  });
  const ran = (needle: RegExp | string) =>
    stmts.filter((s) => (typeof needle === "string" ? s.text.includes(needle) : needle.test(s.text)));
  return { sql, stmts, ran };
}

const CLAIM_READ = /AS winback_eligible, \(.*\) AS offer_eligible FROM subscriptions AS s WHERE/;
const CLAIM = /^INSERT INTO subscriptions \( user_id, status, plan/;
const SWITCH = /^UPDATE subscriptions AS s SET status = CASE WHEN s\.trial_end IS NOT NULL/;
const HONOUR = /^UPDATE subscriptions AS s SET merchant_subscription_id = s\.offer_mandate_id/;
const GRANT = /AND s\.status = 'pending' AND NOT s\.offer_switch/;
const RELEASE = /AS released_mandate_id/;
const STATUS_READ = /^SELECT id, user_id, status, plan, merchant_subscription_id/;
const CANCEL_READ = /^SELECT merchant_subscription_id, superseded_mandate_id, offer_mandate_id/;
const CANCEL_WRITE = /^UPDATE subscriptions AS s SET status = 'cancelled', merchant_subscription_id = CASE/;
const ABANDON_READ = /^SELECT status, merchant_subscription_id FROM subscriptions WHERE user_id = \?/;
const OFFERS_SELECT = /^SELECT id, offer_mandate_id FROM subscriptions/;
const PASS_A = /^SELECT id, user_id, merchant_subscription_id, next_debit_at, debit_count/;
const PASS_B = /^SELECT id, user_id, status, merchant_subscription_id, redemption_order_id/;
const NOTIFIED = /^UPDATE subscriptions SET notified_at = now\(\), redemption_order_id = \?/;
const SETTLE = /^UPDATE subscriptions SET status = 'active', current_period_end = \?/;

interface PpCall {
  merchant: "legacy" | "hsr" | "none";
  method: string;
  path: string;
  body: J | null;
}
interface PpScript {
  mandate?: (id: string) => string | undefined;
  order?: (id: string) => J | undefined;
  redeem?: () => J | undefined;
}

let pp: { calls: PpCall[] } = { calls: [] };

function fakePhonePe(script: PpScript = {}) {
  const calls: PpCall[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const url = new URL(input);
      const raw = typeof init.body === "string" ? init.body : "";
      if (url.pathname.endsWith("/oauth/token")) {
        const clientId = new URLSearchParams(raw).get("client_id") ?? "";
        return Response.json({
          access_token: `tok:${clientId}`,
          expires_at: Math.floor(Date.now() / 1000) + 3600,
        });
      }
      const auth = (init.headers as Record<string, string> | undefined)?.Authorization ?? "";
      const merchant =
        auth === "O-Bearer tok:legacy-client"
          ? "legacy"
          : auth === "O-Bearer tok:hsr-client"
            ? "hsr"
            : "none";
      const path = decodeURIComponent(url.pathname).replace(/^\/apis\/pg-sandbox/, "");
      const body = raw.startsWith("{") ? (JSON.parse(raw) as J) : null;
      calls.push({ merchant, method: init.method ?? "GET", path, body });
      const orderAt = /^\/subscriptions\/v2\/order\/([^/]+)\/status$/.exec(path);
      if (orderAt) {
        return Response.json({
          merchantOrderId: orderAt[1],
          orderId: `OMO_${orderAt[1]}`,
          expireAt: Date.now() + DAY,
          ...(script.order?.(orderAt[1]) ?? { state: "PENDING" }),
        });
      }
      const mandateAt = /^\/subscriptions\/v2\/([^/]+)\/status$/.exec(path);
      if (mandateAt) {
        const state = script.mandate?.(mandateAt[1]) ?? "ACTIVE";
        return Response.json({ merchantSubscriptionId: mandateAt[1], subscriptionId: "OMS_LIVE", state });
      }
      if (/\/cancel$/.test(path)) return new Response(null, { status: 204 });
      if (path === "/subscriptions/v2/setup") {
        return Response.json({ orderId: "OMO_INT", state: "PENDING", intentUrl: "upi://mandate?pa=x" });
      }
      if (path === "/subscriptions/v2/notify") {
        return Response.json({ orderId: "OMO_N", state: "NOTIFIED", expireAt: Date.now() + DAY });
      }
      if (path === "/subscriptions/v2/redeem") {
        return Response.json(script.redeem?.() ?? { state: "PENDING", transactionId: "TXN" });
      }
      return new Response("unexpected", { status: 500 });
    }),
  );
  pp = { calls };
  return pp;
}

function expectOneMerchantPerCall(calls: PpCall[]) {
  for (const call of calls) {
    const ids = `${call.path} ${JSON.stringify(call.body ?? {})}`.match(/DKS_[A-Za-z0-9_-]+/g) ?? [];
    expect(ids.length, call.path).toBeGreaterThan(0);
    for (const id of ids) expect(call.merchant, `${call.path} named ${id}`).toBe(merchantOf(id));
  }
}

const trace = (calls: PpCall[]) =>
  calls.map((c) => {
    if (c.path.endsWith("/cancel")) return [c.merchant, "revoke", c.path.split("/").at(-2)];
    if (c.path.includes("/order/")) return [c.merchant, "order-status", c.path.split("/").at(-2)];
    if (c.path.endsWith("/status")) return [c.merchant, "mandate-status", c.path.split("/").at(-2)];
    if (c.path.endsWith("/notify"))
      return [c.merchant, "notify", (c.body?.paymentFlow as J | undefined)?.merchantSubscriptionId];
    if (c.path.endsWith("/redeem")) return [c.merchant, "redeem", c.body?.merchantOrderId];
    return [c.merchant, "setup", (c.body?.paymentFlow as J | undefined)?.merchantSubscriptionId];
  });

function hsrEnv(): Env {
  return makeEnv({
    PHONEPE_MERCHANT_ID: "AUTOGRAMAPPSONLINE",
    PHONEPE_CLIENT_ID: "legacy-client",
    PHONEPE_CLIENT_SECRET: "legacy-secret",
    PHONEPE_HSR_MERCHANT_ID: "HSRUTILITYONLINE",
    PHONEPE_HSR_CLIENT_ID: "hsr-client",
    PHONEPE_HSR_CLIENT_SECRET: "hsr-secret",
    PHONEPE_HSR_CLIENT_VERSION: "1",
    PHONEPE_HSR_WEBHOOK_USERNAME: "hsruser",
    PHONEPE_HSR_WEBHOOK_PASSWORD: "hsrpass",
    PHONEPE_SETUP_MERCHANT: "hsr",
  });
}

async function call(
  handler: (c: Context<{ Bindings: Env }>) => Promise<Response>,
  route: Route,
  opts: { token?: string; auth?: string; body?: unknown } = {},
) {
  const env = hsrEnv();
  const db = routedSql(route);
  (env as unknown as { _testSql: unknown })._testSql = db.sql;
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
  const res = await handler(c);
  await Promise.all(pending);
  const body = (await res
    .clone()
    .json()
    .catch(() => null)) as J | null;
  return { res, body, db };
}

let token: string;
let hsrAuth: string;
beforeAll(async () => {
  token = await signAccessToken(USER_ID, makeEnv().JWT_SECRET);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("hsruser:hsrpass"));
  hsrAuth = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
});

afterEach(() => {
  expectOneMerchantPerCall(pp.calls);
  pp = { calls: [] };
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  vi.useRealTimers();
});

describe.each([
  ["legacy ₹199 (DKS_S_) -> hsr ₹99 (DKS_HS_)", LEGACY_199],
  ["hsr ₹199 (DKS_HS_) -> hsr ₹99 (DKS_HS_)", HSR_199],
])("%s with PHONEPE_SETUP_MERCHANT=hsr", (_journey, parked) => {
  const parkedAt = merchantOf(parked);
  const subscriber: J = {
    id: "row-1",
    user_id: USER_ID,
    trial_end: ago(40 * DAY),
    status: "active",
    plan: "monthly",
    merchant_subscription_id: parked,
    superseded_mandate_id: null,
    superseded_price_paise: null,
    price_paise: "19900",
    offer_mandate_id: null,
    redemption_order_id: null,
    current_period_end: ahead(10 * DAY),
    updated_at: ago(DAY),
  };
  const midSwitch: J = {
    ...subscriber,
    status: "pending",
    merchant_subscription_id: HSR_99,
    merchant_order_id: HSR_99_ORDER,
    superseded_mandate_id: parked,
    superseded_price_paise: "19900",
    price_paise: "9900",
    offer_switch: true,
  };

  it("1. /me offers it; initiate parks the ₹199 at its price and sets up the ₹99 at hsr", async () => {
    const { calls } = fakePhonePe();
    const me = await call(
      handleMe,
      () => [{ id: USER_ID, sub_id: "row-1", sub_price_paise: "19900", sub_cancel_offer_eligible: true }],
      { token },
    );
    expect(me.body?.subscription).toMatchObject({ price_paise: 19900, cancel_offer_eligible: true });

    const { body, db } = await call(
      handleInitiate,
      (t) => (CLAIM_READ.test(t) ? [{ ...subscriber, offer_eligible: true }] : undefined),
      { token, body: { plan: "monthly", offer: "cancel_99", targetApp: "com.phonepe.app" } },
    );
    const minted = String(body?.merchantSubscriptionId);
    expect(minted).toMatch(/^DKS_HS_/);
    expect(body).toMatchObject({
      amountPaise: 200,
      trialEligible: false,
      offer: "cancel_99",
      pricePaise: 9900,
    });
    expect(db.ran(CLAIM)[0].values.slice(2, 10)).toEqual([
      minted,
      expect.stringMatching(/^DKS_HS_/),
      "com.phonepe.app",
      parked,
      19900,
      9900,
      true,
      null,
    ]);
    expect(trace(calls)).toEqual([
      [parkedAt, "mandate-status", parked],
      ["hsr", "setup", minted],
    ]);
  });

  it("2. the setup-completed webhook switches the row, and the ₹199 is revoked where it lives", async () => {
    const { calls } = fakePhonePe();
    const { res, db } = await call(
      handleWebhook,
      (t) =>
        SWITCH.test(t)
          ? [{ user_id: USER_ID, status: "active", price_paise: "9900", stale_mandate_id: parked }]
          : undefined,
      {
        auth: hsrAuth,
        body: {
          event: "subscription.setup.order.completed",
          payload: {
            merchantId: "HSRUTILITYONLINE",
            merchantOrderId: HSR_99_ORDER,
            orderId: "OMO_S",
            state: "COMPLETED",
            amount: 200,
            paymentFlow: {
              type: "SUBSCRIPTION_SETUP",
              merchantSubscriptionId: HSR_99,
              subscriptionId: "OMS_99",
            },
          },
        },
      },
    );
    expect(res.status).toBe(200);
    expect(db.ran(SWITCH)).toHaveLength(1);
    expect(db.ran(GRANT)).toEqual([]);
    expect(trace(calls)).toEqual([[parkedAt, "revoke", parked]]);
  });

  it("3. the first ₹99 is notified for 9900 and redeemed, both at hsr", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-01T10:20:00Z"));
    const switched = { ...subscriber, merchant_subscription_id: HSR_99, price_paise: "9900", debit_count: 1 };
    const cron = async (route: Route) => {
      const env = hsrEnv();
      const db = routedSql(
        (t, v) => route(t, v) ?? (/min\(next_debit_at\)/.test(t) ? [{ soonest: null }] : undefined),
      );
      (env as unknown as { _testSql: unknown })._testSql = db.sql;
      await runAutopayNotify(env);
      return db;
    };

    const notify = fakePhonePe();
    const first = await cron((t) =>
      PASS_A.test(t) ? [{ ...switched, next_debit_at: ahead(23 * HOUR).toISOString() }] : undefined,
    );
    const redemption = String(first.ran(NOTIFIED)[0].values[0]);
    expect(redemption).toMatch(/^DKS_HR_/);
    expect(trace(notify.calls)).toEqual([
      ["hsr", "mandate-status", HSR_99],
      ["hsr", "notify", HSR_99],
    ]);
    expect(notify.calls[1].body).toMatchObject({ amount: 9900, merchantOrderId: redemption });
    expectOneMerchantPerCall(notify.calls);

    vi.setSystemTime(new Date("2026-10-02T11:20:00Z"));
    const redeem = fakePhonePe({ redeem: () => ({ state: "COMPLETED", transactionId: "TXN" }) });
    const second = await cron((t) => {
      if (PASS_B.test(t)) {
        return [
          {
            ...switched,
            status: "trialing",
            redemption_order_id: redemption,
            retry_count: 0,
            next_debit_at: ago(30 * MIN).toISOString(),
            notified_at: ago(25 * HOUR).toISOString(),
          },
        ];
      }
      return SETTLE.test(t) ? [{ updated_at: new Date() }] : undefined;
    });
    expect(trace(redeem.calls)).toEqual([["hsr", "redeem", redemption]]);
    expect(second.ran(SETTLE)[0].text).toContain("paid_paise = paid_paise + price_paise");
    expect(reportPostHogFirstConversion).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ amountPaise: 9900, transactionId: redemption }),
    );
  });

  it("4. an abandoned switch releases to the ₹199, which is then read where it lives", async () => {
    const { calls } = fakePhonePe();
    const abandon = await call(
      handleAbandon,
      (t) => {
        if (ABANDON_READ.test(t)) return [{ status: "pending", merchant_subscription_id: HSR_99 }];
        if (RELEASE.test(t)) {
          return [
            {
              user_id: USER_ID,
              status: "active",
              merchant_subscription_id: parked,
              released_mandate_id: HSR_99,
            },
          ];
        }
        return undefined;
      },
      { token, body: { merchantOrderId: HSR_99_ORDER } },
    );
    expect(abandon.body).toEqual({ abandoned: true, settled: false });

    const status = await call(
      handleStatus,
      (t) => (STATUS_READ.test(t) ? [{ ...subscriber, merchant_order_id: HSR_99_ORDER }] : undefined),
      { token },
    );
    expect(status.body?.subscription).toMatchObject({ merchant_subscription_id: parked, price_paise: 19900 });
    expect(trace(calls)).toEqual([
      ["hsr", "order-status", HSR_99_ORDER],
      ["hsr", "revoke", HSR_99],
      [parkedAt, "mandate-status", parked],
    ]);
  });

  it("5. a late ACTIVE on the released hsr ₹99 is honoured, and the ₹199 revoked where it lives", async () => {
    const { calls } = fakePhonePe();
    const db = routedSql((t) => {
      if (OFFERS_SELECT.test(t)) return [{ id: "row-1", offer_mandate_id: HSR_99 }];
      if (HONOUR.test(t))
        return [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: parked }];
      return undefined;
    });
    await runHourlySweeps(hsrEnv(), db.sql as never, { take: () => true });
    expect(db.ran(HONOUR)).toHaveLength(1);
    expect(trace(calls)).toEqual([
      ["hsr", "mandate-status", HSR_99],
      [parkedAt, "revoke", parked],
    ]);
  });

  it("6. cancel mid-switch revokes the ₹199 and the unapproved ₹99, each where it lives", async () => {
    const { calls } = fakePhonePe();
    const { res, db } = await call(
      handleCancel,
      (t) => {
        if (CANCEL_READ.test(t)) return [midSwitch];
        if (CANCEL_WRITE.test(t))
          return [{ updated_at: new Date(), price_paise: "19900", merchant_subscription_id: parked }];
        return undefined;
      },
      { token, body: { offer_declined: true } },
    );
    expect(res.status).toBe(200);
    // The fielded decline body is accepted and records nothing: the offer keeps no per-person answer
    expect(db.ran(CANCEL_WRITE)[0].text).not.toContain("users");
    expect(trace(calls)).toEqual([
      [parkedAt, "revoke", parked],
      ["hsr", "revoke", HSR_99],
    ]);
  });
});
