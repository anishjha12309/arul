/**
 * The ₹99 cancel-save offer through the routes: initiate, webhook, status, cancel, abandon, /me, DELETE /me and
 * /auth/login. There is no Postgres here -> assertions read SQL text, bound values and statement order, and
 * lib/phonepe.ts runs for real against a stub that names the merchant each call authenticated as
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
vi.mock("../src/lib/google.js", async (importOriginal) => ({
  GoogleKeysUnavailableError: (await importOriginal<typeof import("../src/lib/google.js")>())
    .GoogleKeysUnavailableError,
  verifyGoogleIdToken: vi.fn(),
}));

import { verifyGoogleIdToken } from "../src/lib/google.js";
import { signAccessToken } from "../src/lib/jwt.js";
import { merchantOf } from "../src/lib/phonepe.js";
import { reportPostHogFirstConversion, reportPostHogSubscriptionCancel } from "../src/lib/posthog.js";
import { grantReferralReward } from "../src/lib/referral.js";
import { handleLogin } from "../src/routes/auth.js";
import { handleDeleteAccount, handleMe, handleMeSubscription } from "../src/routes/me.js";
import {
  handleAbandon,
  handleCancel,
  handleInitiate,
  handleStatus,
  handleWebhook,
} from "../src/routes/payments.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const LEGACY_199 = "DKS_S_550E8400_MFX1K2A0";
const HSR_99 = "DKS_HS_550E8400_MG2B7Q10";
const HSR_99_ORDER = "DKS_HS_550E8400_MG2B7Q10_1A2B";
const OLD_99 = "DKS_HS_550E8400_MF0AAAA0";
const LEGACY_R = "DKS_R_550E8400_MG9C1D00_7F3A";
const HSR_R = "DKS_HR_550E8400_MGAB0000_0C1D";
const HOUR = 3_600_000;
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

const CLAIM_READ = /AS offer_eligible FROM subscriptions AS s JOIN users AS u/;
const LOCK = /^SELECT 1 FROM users WHERE id = \? FOR UPDATE$/;
const CLAIM = /^INSERT INTO subscriptions \( user_id, status, plan/;
const PARK = /^UPDATE subscriptions AS s SET status = \?, next_debit_at = NULL, notified_at = NULL/;
const RELEASE = /AS released_mandate_id/;
const SWITCH = /^WITH g AS \( UPDATE subscriptions AS s SET status = CASE/;
const HONOUR = /^WITH g AS \( UPDATE subscriptions AS s SET merchant_subscription_id = s\.offer_mandate_id/;
const GRANT = /AND s\.status = 'pending' AND NOT s\.offer_switch/;
const RESURRECT = /AND s\.status IN \('expired', 'cancelled'\) AND NOT s\.offer_switch/;
const WATCHED = /^SELECT 1 FROM subscriptions WHERE offer_mandate_id = \?/;
const HEAL_CANDIDATE =
  /^SELECT COALESCE\(s\.superseded_mandate_id, s\.merchant_subscription_id\) AS mandate_id/;
const HEAL = /^UPDATE subscriptions AS s SET status = \?, merchant_subscription_id = COALESCE/;
const NOTE_RETRY = /^UPDATE subscriptions SET revoke_retry_mandate_id = \?/;
const STATUS_READ = /^SELECT id, user_id, status, plan, merchant_subscription_id/;
const CANCEL_READ = /^SELECT merchant_subscription_id, superseded_mandate_id, offer_mandate_id/;
const CANCEL_WRITE = /^WITH c AS \( UPDATE subscriptions AS s SET status = 'cancelled'/;
const ABANDON_READ = /^SELECT status, merchant_subscription_id FROM subscriptions WHERE user_id = \?/;
const WEBHOOK_CANCEL = /^UPDATE subscriptions AS s SET status = 'cancelled', next_debit_at = NULL/;
const CLEAR_IDS = /^UPDATE subscriptions SET superseded_mandate_id = CASE WHEN superseded_mandate_id = \?/;
const UNWATCH = /^UPDATE subscriptions SET offer_mandate_id = NULL WHERE offer_mandate_id = \?/;
const SETTLE = /^UPDATE subscriptions AS s SET status = 'active', merchant_subscription_id = \?/;

const LABELS: [string, RegExp][] = [
  ["claim-read", CLAIM_READ],
  ["lock", LOCK],
  ["claim", CLAIM],
  ["attach", /^UPDATE subscriptions SET phonepe_order_id = \?/],
  ["park", PARK],
  ["release", RELEASE],
  ["switch", SWITCH],
  ["honour", HONOUR],
  ["grant", GRANT],
  ["resurrect", RESURRECT],
  ["watched", WATCHED],
  ["heal-candidate", HEAL_CANDIDATE],
  ["heal", HEAL],
  ["note-retry", NOTE_RETRY],
  ["unwatch", UNWATCH],
  ["diag", /^UPDATE subscriptions SET phonepe_subscription_id = COALESCE\(phonepe_subscription_id/],
];
const order = (db: ReturnType<typeof routedSql>) =>
  db.stmts.map((s) => LABELS.find(([, re]) => re.test(s.text))?.[0] ?? s.text.slice(0, 40));

interface PpCall {
  merchant: "legacy" | "hsr" | "none";
  method: string;
  path: string;
  body: J | null;
}
interface PpScript {
  mandate?: (id: string) => string | Response | undefined;
  order?: (id: string) => J | Response | undefined;
  cancel?: (id: string) => Response | undefined;
  intent?: () => Response | undefined;
  sdk?: () => Response | undefined;
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
        const a = script.order?.(orderAt[1]) ?? { state: "PENDING" };
        if (a instanceof Response) return a;
        return Response.json({
          merchantOrderId: orderAt[1],
          orderId: `OMO_${orderAt[1]}`,
          expireAt: Date.now() + DAY,
          ...a,
        });
      }
      const mandateAt = /^\/subscriptions\/v2\/([^/]+)\/status$/.exec(path);
      if (mandateAt) {
        const a = script.mandate?.(mandateAt[1]) ?? "ACTIVE";
        return a instanceof Response
          ? a
          : Response.json({ merchantSubscriptionId: mandateAt[1], subscriptionId: "OMS_LIVE", state: a });
      }
      const cancelAt = /^\/(?:subscriptions\/v2|checkout\/v2\/subscriptions)\/([^/]+)\/cancel$/.exec(path);
      if (cancelAt) return script.cancel?.(cancelAt[1]) ?? new Response(null, { status: 204 });
      if (path === "/subscriptions/v2/setup") {
        return (
          script.intent?.() ??
          Response.json({ orderId: "OMO_INT", state: "PENDING", intentUrl: "upi://mandate?pa=x" })
        );
      }
      if (path === "/checkout/v2/sdk/order") {
        return script.sdk?.() ?? Response.json({ orderId: "OMO_SDK", state: "PENDING", token: "SDKTOKEN" });
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

// The cancel fallback path repeats the id -> one entry per mandate, at the first path
const revokes = (calls: PpCall[]) => {
  const seen = new Map<string, string>();
  for (const c of calls) {
    const m = /\/([^/]+)\/cancel$/.exec(c.path);
    if (m && !seen.has(m[1])) seen.set(m[1], c.merchant);
  }
  return [...seen].map(([id, merchant]) => [merchant, id]);
};

const refuseCancel = () => new Response('{"code":"BAD_REQUEST"}', { status: 400 });

function dualEnv(overrides: Record<string, unknown> = {}): Env {
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
    TRIAL_TOMBSTONE_SECRET: "test-tombstone-secret",
    ...overrides,
  });
}

interface CallOpts {
  token?: string;
  auth?: string;
  body?: unknown;
  noBody?: boolean;
}

// waitUntil work is awaited -> the background revokes are part of what each test asserts
async function call(
  handler: (c: Context<{ Bindings: Env }>) => Promise<Response>,
  route: Route,
  opts: CallOpts = {},
  env: Env = dualEnv(),
) {
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
      json: () =>
        opts.noBody
          ? Promise.reject(new SyntaxError("Unexpected end of JSON input"))
          : Promise.resolve(opts.body ?? {}),
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
  return { res, body, db, env };
}

const errorCode = (body: J | null) => (body?.error as J | undefined)?.code;

let token: string;
beforeAll(async () => {
  token = await signAccessToken(USER_ID, makeEnv().JWT_SECRET);
});

afterEach(() => {
  expectOneMerchantPerCall(pp.calls);
  pp = { calls: [] };
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("POST /payments/initiate {offer: 'cancel_99'}", () => {
  const eligible = (patch: J = {}): J => ({
    trial_end: ago(40 * DAY),
    status: "active",
    merchant_subscription_id: LEGACY_199,
    superseded_mandate_id: null,
    superseded_price_paise: null,
    price_paise: "19900",
    offer_mandate_id: null,
    redemption_order_id: null,
    current_period_end: ahead(20 * DAY),
    updated_at: ago(DAY),
    offer_eligible: true,
    ...patch,
  });

  const initiate = (body: J, claimRows: (read: number) => unknown[], extra: Route = () => undefined) => {
    let reads = 0;
    return call(
      handleInitiate,
      (t, v) => {
        const answer = extra(t, v);
        if (answer !== undefined) return answer;
        if (CLAIM_READ.test(t)) {
          reads += 1;
          return claimRows(reads);
        }
        return undefined;
      },
      { token, body },
    );
  };
  const OFFER = { plan: "monthly", offer: "cancel_99", targetApp: "com.phonepe.app" };

  it("parks the live ₹199 at its price and sets up a ₹2 PENNY_DROP ₹99 mandate at the setup merchant", async () => {
    const { calls } = fakePhonePe();
    const { res, body, db } = await initiate(OFFER, () => [eligible()]);

    expect(res.status).toBe(200);
    expect(body).toMatchObject({
      flow: "intent",
      trialEligible: false,
      amountPaise: 200,
      offer: "cancel_99",
      pricePaise: 9900,
    });
    const msid = String(body?.merchantSubscriptionId);
    const moid = String(body?.merchantOrderId);
    expect(msid).toMatch(/^DKS_HS_550E8400_/);
    expect(moid).toMatch(/^DKS_HS_550E8400_/);
    expect(calls.map((c) => [c.merchant, c.method, c.path])).toEqual([
      ["legacy", "GET", `/subscriptions/v2/${LEGACY_199}/status`],
      ["hsr", "POST", "/subscriptions/v2/setup"],
    ]);
    expect(calls[1].body).toMatchObject({
      merchantOrderId: moid,
      amount: 200,
      paymentFlow: {
        type: "SUBSCRIPTION_SETUP",
        merchantSubscriptionId: msid,
        authWorkflowType: "PENNY_DROP",
        amountType: "FIXED",
        maxAmount: 9900,
      },
    });
    expect(order(db)).toEqual(["claim-read", "lock", "claim-read", "claim", "attach"]);
    const claim = db.ran(CLAIM)[0];
    expect(claim.values).toEqual([
      USER_ID,
      "monthly",
      msid,
      moid,
      "com.phonepe.app",
      LEGACY_199,
      19900,
      9900,
      true,
      null,
    ]);
    for (const set of [
      "superseded_price_paise = EXCLUDED.superseded_price_paise",
      "price_paise = EXCLUDED.price_paise",
      "offer_switch = EXCLUDED.offer_switch",
      "offer_mandate_id = NULL",
    ]) {
      expect(claim.text).toContain(set);
    }
  });

  it("the SDK-page path carries the same ₹99 mandate and the hsr merchant id", async () => {
    const { calls } = fakePhonePe();
    const { body } = await initiate({ plan: "monthly", offer: "cancel_99" }, () => [eligible()]);

    expect(body).toMatchObject({
      merchantId: "HSRUTILITYONLINE",
      trialEligible: false,
      amountPaise: 200,
      offer: "cancel_99",
      pricePaise: 9900,
    });
    expect(calls.map((c) => [c.merchant, c.path])).toEqual([
      ["legacy", `/subscriptions/v2/${LEGACY_199}/status`],
      ["hsr", "/checkout/v2/sdk/order"],
    ]);
    expect(calls[1].body).toMatchObject({
      amount: 200,
      paymentFlow: {
        subscriptionDetails: { authWorkflowType: "PENNY_DROP", maxAmount: 9900, amountType: "FIXED" },
      },
    });
  });

  it("a fresh attempt revokes a released switch's ₹99 still being watched, at its own merchant", async () => {
    const { calls } = fakePhonePe();
    const { res } = await initiate(OFFER, () => [eligible({ offer_mandate_id: OLD_99 })]);
    expect(res.status).toBe(200);
    expect(revokes(calls)).toEqual([["hsr", OLD_99]]);
  });

  it.each([
    [
      "due within the hour",
      { next_debit_at: ahead(30 * 60_000) },
      "s.next_debit_at > now() + interval '1 hour'",
    ],
    ["a parked mandate", { superseded_mandate_id: HSR_99 }, "s.superseded_mandate_id IS NULL"],
    ["already on ₹99", { price_paise: "9900" }, "s.price_paise = ?"],
    ["the offer already spent", { cancel_offer_at: ago(DAY) }, "u.cancel_offer_at IS NULL"],
    ["not trialing or active", { status: "paused" }, "s.status IN ('trialing', 'active')"],
    ["the period over", { current_period_end: ago(HOUR) }, "s.current_period_end > now()"],
    ["no live mandate", { merchant_subscription_id: null }, "s.merchant_subscription_id IS NOT NULL"],
  ])(
    "ineligible (%s) -> 409 offer_unavailable before any PhonePe call or claim",
    async (_why, patch, clause) => {
      fakePhonePe();
      const { res, body, db } = await initiate(OFFER, () => [eligible({ ...patch, offer_eligible: false })]);

      expect(res.status).toBe(409);
      expect(errorCode(body)).toBe("offer_unavailable");
      const read = db.ran(CLAIM_READ)[0];
      expect(read.text).toContain(clause);
      expect(read.values).toEqual([19900, USER_ID]);
      expect(order(db)).toEqual(["claim-read"]);
      expect(pp.calls).toEqual([]);
    },
  );

  it("a user with no subscription row is never offered it", async () => {
    fakePhonePe();
    const { res, body } = await initiate(OFFER, () => []);
    expect(res.status).toBe(409);
    expect(errorCode(body)).toBe("offer_unavailable");
  });

  it("re-checked under the lock: a row gone ineligible answers offer_unavailable, never already_subscribed", async () => {
    fakePhonePe();
    const { res, body, db } = await initiate(OFFER, (read) =>
      read === 1 ? [eligible()] : [eligible({ price_paise: "9900", offer_eligible: false })],
    );
    expect(res.status).toBe(409);
    expect(errorCode(body)).toBe("offer_unavailable");
    expect(order(db)).toEqual(["claim-read", "lock", "claim-read"]);
  });

  it.each([
    ["REVOKED", "cancelled", "s.status IN ('trialing', 'active', 'paused')"],
    ["CANCELLED", "cancelled", "s.status IN ('trialing', 'active', 'paused')"],
    ["PAUSED", "paused", "(s.status IN ('trialing', 'active'))"],
  ])("a live mandate PhonePe reads %s syncs the row (%s) and refuses", async (state, parked, scope) => {
    fakePhonePe({ mandate: () => state });
    const { res, body, db } = await initiate(OFFER, () => [eligible()]);

    expect(res.status).toBe(409);
    expect(errorCode(body)).toBe("offer_unavailable");
    expect(order(db)).toEqual(["claim-read", "park"]);
    const park = db.ran(PARK)[0];
    expect(park.values).toEqual([parked, USER_ID]);
    expect(park.text).toContain("WHERE (s.user_id = ?) AND prior.id = s.id");
    expect(park.text).toContain(scope);
  });

  it("a live mandate still in flight at PhonePe refuses without writing", async () => {
    fakePhonePe({ mandate: () => "ACTIVATION_IN_PROGRESS" });
    const { res, body, db } = await initiate(OFFER, () => [eligible()]);
    expect(res.status).toBe(409);
    expect(errorCode(body)).toBe("offer_unavailable");
    expect(order(db)).toEqual(["claim-read"]);
  });

  it("a failed live-mandate read is a 502 that changes nothing", async () => {
    fakePhonePe({ mandate: () => new Response("down", { status: 503 }) });
    const { res, body, db } = await initiate(OFFER, () => [eligible()]);
    expect(res.status).toBe(502);
    expect(errorCode(body)).toBe("phonepe_error");
    expect(order(db)).toEqual(["claim-read"]);
  });

  it.each([["cancel_49"], [99], [true], [{ id: "cancel_99" }], [""]])(
    "an unknown offer %j is 400 invalid_offer, never a full-price checkout",
    async (offer) => {
      fakePhonePe();
      const { res, body, db } = await initiate({ plan: "monthly", offer }, () => [eligible()]);
      expect(res.status).toBe(400);
      expect(errorCode(body)).toBe("invalid_offer");
      expect(db.stmts).toEqual([]);
      expect(pp.calls).toEqual([]);
    },
  );

  it("offer: null is a plain ₹199 checkout", async () => {
    const { calls } = fakePhonePe();
    const { res, body, db } = await initiate(
      { plan: "monthly", offer: null, targetApp: "com.phonepe.app" },
      () => [],
    );
    expect(res.status).toBe(200);
    expect(body).not.toHaveProperty("offer");
    expect(body).toMatchObject({ trialEligible: true, amountPaise: 200 });
    expect(db.ran(CLAIM)[0].values.slice(5, 9)).toEqual([null, null, 19900, false]);
    expect(calls[0].body).toMatchObject({ paymentFlow: { maxAmount: 19900 } });
  });

  it("both setup paths failing releases an offer claim at once, scoped to the claimed order", async () => {
    const down = () => new Response("down", { status: 500 });
    const { calls } = fakePhonePe({ intent: down, sdk: down });
    const { res, body, db } = await initiate(OFFER, () => [eligible()]);

    expect(res.status).toBe(502);
    expect(errorCode(body)).toBe("phonepe_error");
    expect(calls.map((c) => [c.merchant, c.path])).toEqual([
      ["legacy", `/subscriptions/v2/${LEGACY_199}/status`],
      ["hsr", "/subscriptions/v2/setup"],
      ["hsr", "/checkout/v2/sdk/order"],
    ]);
    expect(order(db)).toEqual(["claim-read", "lock", "claim-read", "claim", "release"]);
    const claimedOrder = db.ran(CLAIM)[0].values[3];
    const release = db.ran(RELEASE)[0];
    expect(release.text).toContain("WHERE (s.user_id = ? AND s.merchant_order_id = ?) AND prior.id = s.id");
    expect(release.values).toEqual([19900, USER_ID, claimedOrder]);
  });

  it("a plain checkout failing both paths keeps its claim pending", async () => {
    const down = () => new Response("down", { status: 500 });
    fakePhonePe({ intent: down, sdk: down });
    const { res, db } = await initiate({ plan: "monthly", targetApp: "com.phonepe.app" }, () => []);
    expect(res.status).toBe(502);
    expect(db.ran(RELEASE)).toEqual([]);
  });

  it("lapse -> re-subscribe over a ₹99 row writes price 19900 and parks the ₹99 at its own price", async () => {
    const { calls } = fakePhonePe();
    const lapsed = eligible({
      merchant_subscription_id: HSR_99,
      price_paise: "9900",
      current_period_end: ago(3 * DAY),
      offer_eligible: false,
    });
    const { res, body, db } = await initiate({ plan: "monthly", targetApp: "com.phonepe.app" }, () => [
      lapsed,
    ]);

    expect(res.status).toBe(200);
    expect(body).toMatchObject({ trialEligible: false, amountPaise: 19900 });
    expect(body).not.toHaveProperty("offer");
    expect(db.ran(CLAIM)[0].values.slice(5, 9)).toEqual([HSR_99, 9900, 19900, false]);
    expect(calls.map((c) => c.path)).toEqual(["/subscriptions/v2/setup"]);
    expect(calls[0].body).toMatchObject({
      amount: 19900,
      paymentFlow: { authWorkflowType: "TRANSACTION", maxAmount: 19900 },
    });
  });

  it("a paused ₹99 row re-subscribing parks the ₹99 too", async () => {
    fakePhonePe();
    const paused = eligible({ status: "paused", merchant_subscription_id: HSR_99, price_paise: 9900 });
    const { db } = await initiate({ plan: "monthly", targetApp: "com.phonepe.app" }, () => [
      { ...paused, offer_eligible: false },
    ]);
    expect(db.ran(CLAIM)[0].values.slice(5, 9)).toEqual([HSR_99, 9900, 19900, false]);
  });

  it("a re-subscribe over a stale pending switch keeps the parked ₹199 at its price and revokes the unapproved ₹99", async () => {
    const { calls } = fakePhonePe();
    const pendingSwitch = eligible({
      status: "pending",
      merchant_subscription_id: HSR_99,
      superseded_mandate_id: LEGACY_199,
      superseded_price_paise: "19900",
      price_paise: "9900",
      updated_at: ago(HOUR),
      offer_eligible: false,
    });
    const { db } = await initiate({ plan: "monthly", targetApp: "com.phonepe.app" }, () => [pendingSwitch]);
    expect(db.ran(CLAIM)[0].values.slice(5, 9)).toEqual([LEGACY_199, 19900, 19900, false]);
    expect(revokes(calls)).toEqual([["hsr", HSR_99]]);
  });

  describe("7c — a re-subscribe over a settled debit heals instead of claiming", () => {
    const lapsedWithOrder = eligible({
      status: "cancelled",
      redemption_order_id: LEGACY_R,
      trial_end: ago(3 * DAY),
      current_period_end: ago(3 * DAY),
      offer_eligible: false,
    });

    it("COMPLETED -> heal once, 409 already_subscribed, no claim", async () => {
      const { calls } = fakePhonePe({ order: () => ({ state: "COMPLETED" }) });
      const { res, body, db } = await initiate(
        { plan: "monthly" },
        () => [lapsedWithOrder],
        (t) => {
          if (HEAL_CANDIDATE.test(t)) return [{ mandate_id: LEGACY_199 }];
          if (HEAL.test(t)) {
            return [
              {
                user_id: USER_ID,
                status: "active",
                merchant_subscription_id: LEGACY_199,
                price_paise: 19900,
                prior_mandate_id: LEGACY_199,
              },
            ];
          }
          return undefined;
        },
      );

      expect(res.status).toBe(409);
      expect(errorCode(body)).toBe("already_subscribed");
      expect(order(db)).toEqual(["claim-read", "heal-candidate", "heal"]);
      expect(db.ran(HEAL)[0].text).toContain(
        "WHERE (s.user_id = ?) AND prior.id = s.id AND s.redemption_order_id = ?",
      );
      expect(calls.map((c) => [c.merchant, c.path])).toEqual([
        ["legacy", `/subscriptions/v2/order/${LEGACY_R}/status`],
        ["legacy", `/subscriptions/v2/${LEGACY_199}/status`],
      ]);
    });

    it("a heal that hands the row back to its parked mandate revokes the unapproved one", async () => {
      const { calls } = fakePhonePe({ order: () => ({ state: "COMPLETED" }) });
      await initiate(
        { plan: "monthly" },
        () => [lapsedWithOrder],
        (t) => {
          if (HEAL_CANDIDATE.test(t)) return [{ mandate_id: LEGACY_199 }];
          if (HEAL.test(t)) {
            return [
              {
                user_id: USER_ID,
                status: "active",
                merchant_subscription_id: LEGACY_199,
                prior_mandate_id: HSR_99,
              },
            ];
          }
          return undefined;
        },
      );
      expect(revokes(calls)).toEqual([["hsr", HSR_99]]);
    });

    it("an order still open -> the claim proceeds", async () => {
      fakePhonePe({ order: () => ({ state: "PENDING" }) });
      const { res, db } = await initiate({ plan: "monthly", targetApp: "com.phonepe.app" }, () => [
        lapsedWithOrder,
      ]);
      expect(res.status).toBe(200);
      expect(db.ran(HEAL)).toEqual([]);
      expect(db.ran(CLAIM)).toHaveLength(1);
    });
  });
});

describe("POST /payments/webhook — the switch, releases and late approvals", () => {
  const setupCompleted = (msid: string, orderId: string) => ({
    event: "subscription.setup.order.completed",
    payload: {
      merchantId: merchantOf(msid) === "hsr" ? "HSRUTILITYONLINE" : "AUTOGRAMAPPSONLINE",
      merchantOrderId: orderId,
      orderId: `OMO_${orderId}`,
      state: "COMPLETED",
      amount: 200,
      paymentFlow: { type: "SUBSCRIPTION_SETUP", merchantSubscriptionId: msid, subscriptionId: "OMS_99" },
    },
  });
  const stateEvent = (event: string, msid: string, state: string) => ({
    event,
    payload: { merchantSubscriptionId: msid, state },
  });
  const deliver = async (body: unknown, route: Route, merchant: "hsr" | "legacy" = "hsr") => {
    const [u, p] = merchant === "hsr" ? ["hsruser", "hsrpass"] : ["u", "p"];
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${u}:${p}`));
    const auth = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return call(handleWebhook, route, { auth, body });
  };
  const switched = {
    user_id: USER_ID,
    status: "trialing",
    price_paise: "9900",
    stale_mandate_id: LEGACY_199,
  };

  it("setup completed on a pending switch -> switch only, and the parked ₹199 revoked at ITS merchant", async () => {
    const { calls } = fakePhonePe();
    const { res, db, env } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) =>
      SWITCH.test(t) ? [switched] : undefined,
    );

    expect(res.status).toBe(200);
    expect(order(db)).toEqual(["switch"]);
    const sw = db.ran(SWITCH)[0];
    expect(sw.text).toContain(
      "WHERE (s.merchant_subscription_id = ?) AND prior.id = s.id AND s.status = 'pending'",
    );
    expect(sw.values).toEqual(["OMS_99", "25 hours", "25 hours", "25 hours", HSR_99]);
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
    expect(grantReferralReward).not.toHaveBeenCalled();
    expect(vi.mocked(env.KV.put).mock.calls.filter(([key]) => key.startsWith("txn:"))).toHaveLength(1);
  });

  it("a ₹199 PhonePe will not revoke is noted for the hourly retry", async () => {
    fakePhonePe({ cancel: refuseCancel });
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) =>
      SWITCH.test(t) ? [switched] : undefined,
    );
    expect(order(db)).toEqual(["switch", "note-retry"]);
    expect(db.ran(NOTE_RETRY)[0].values).toEqual([LEGACY_199, USER_ID]);
  });

  it("a plain setup falls through the switch to the grant", async () => {
    fakePhonePe();
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) =>
      GRANT.test(t)
        ? [{ user_id: USER_ID, status: "trialing", price_paise: 19900, stale_mandate_id: null }]
        : undefined,
    );
    expect(order(db)).toEqual(["switch", "grant"]);
  });

  it("a late approval of a released ₹99 on a row still on its ₹199 is honoured, never resurrected", async () => {
    const { calls } = fakePhonePe();
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) => {
      if (WATCHED.test(t)) return [{ "?column?": 1 }];
      if (HONOUR.test(t))
        return [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 }];
      return undefined;
    });
    expect(order(db)).toEqual(["switch", "grant", "watched", "honour"]);
    expect(db.ran(HONOUR)[0].values).toEqual([
      "OMS_99",
      9900,
      "25 hours",
      "25 hours",
      "25 hours",
      HSR_99,
      19900,
    ]);
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
  });

  it("a late approval on a cancelled row is revoked at its merchant and unwatched, not granted", async () => {
    const { calls } = fakePhonePe();
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) =>
      WATCHED.test(t) ? [{ "?column?": 1 }] : undefined,
    );
    expect(order(db)).toEqual(["switch", "grant", "watched", "honour", "unwatch"]);
    expect(db.ran(UNWATCH)[0].values).toEqual([HSR_99]);
    expect(revokes(calls)).toEqual([["hsr", HSR_99]]);
    expect(grantReferralReward).not.toHaveBeenCalled();
  });

  it("a late approval PhonePe will not revoke stays watched for the sweep", async () => {
    fakePhonePe({ cancel: refuseCancel });
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), (t) =>
      WATCHED.test(t) ? [{ "?column?": 1 }] : undefined,
    );
    expect(db.ran(UNWATCH)).toEqual([]);
  });

  it("the resurrect never matches an offer_switch row", async () => {
    fakePhonePe();
    const { db } = await deliver(setupCompleted(HSR_99, HSR_99_ORDER), () => undefined);
    expect(order(db)).toEqual(["switch", "grant", "watched", "resurrect", "diag"]);
    const resurrect = db.ran(RESURRECT)[0];
    expect(resurrect.text).toContain(
      "WHERE s.merchant_subscription_id = ? AND s.merchant_order_id = ? AND s.status IN ('expired', 'cancelled') " +
        "AND NOT s.offer_switch",
    );
    expect(resurrect.values.slice(-2)).toEqual([HSR_99, HSR_99_ORDER]);
  });

  it("setup failed -> the shared release, by the event's mandate id", async () => {
    fakePhonePe();
    const { db } = await deliver(
      { ...setupCompleted(HSR_99, HSR_99_ORDER), event: "subscription.setup.order.failed" },
      () => undefined,
    );
    expect(order(db)).toEqual(["release"]);
    expect(db.ran(RELEASE)[0].text).toContain("WHERE (s.merchant_subscription_id = ?) AND prior.id = s.id");
  });

  it.each([["subscription.cancelled"], ["subscription.revoked"]])(
    "%s for a pending claim's ₹99 with a parked id -> release, not cancel",
    async (event) => {
      fakePhonePe();
      const { db } = await deliver(stateEvent(event, HSR_99, "CANCELLED"), (t) =>
        RELEASE.test(t)
          ? [
              {
                user_id: USER_ID,
                status: "active",
                merchant_subscription_id: LEGACY_199,
                released_mandate_id: HSR_99,
              },
            ]
          : undefined,
      );
      expect(db.stmts.map((s) => s.text.slice(0, 40))).toHaveLength(1);
      const release = db.ran(RELEASE)[0];
      expect(release.text).toContain(
        "WHERE (s.merchant_subscription_id = ? AND s.superseded_mandate_id IS NOT NULL) AND prior.id = s.id",
      );
      expect(release.values).toEqual([19900, HSR_99]);
      expect(db.ran(WEBHOOK_CANCEL)).toEqual([]);
      expect(reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
    },
  );

  it("a revoked live ₹99 cancels the row and reports the ₹99 price", async () => {
    fakePhonePe();
    const { db } = await deliver(stateEvent("subscription.revoked", HSR_99, "REVOKED"), (t) =>
      WEBHOOK_CANCEL.test(t)
        ? [{ user_id: USER_ID, prior_status: "active", updated_at: new Date(), price_paise: "9900" }]
        : undefined,
    );
    expect(db.ran(RELEASE)).toHaveLength(1);
    expect(db.ran(WEBHOOK_CANCEL)).toHaveLength(1);
    expect(reportPostHogSubscriptionCancel).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ reason: "webhook_revoked", merchantSubId: HSR_99, pricePaise: 9900 }),
    );
  });

  it("a revoked id held only as a watched ₹99 or a revoke retry just clears that column", async () => {
    fakePhonePe();
    const { db } = await deliver(
      stateEvent("subscription.revoked", LEGACY_199, "REVOKED"),
      () => undefined,
      "legacy",
    );
    const clear = db.ran(CLEAR_IDS)[0];
    expect(clear.text).toContain(
      "offer_mandate_id = CASE WHEN offer_mandate_id = ? THEN NULL ELSE offer_mandate_id END",
    );
    expect(clear.text).toContain(
      "revoke_retry_mandate_id = CASE WHEN revoke_retry_mandate_id = ? THEN NULL ELSE revoke_retry_mandate_id END",
    );
    expect(clear.text).toContain(
      "WHERE superseded_mandate_id = ? OR offer_mandate_id = ? OR revoke_retry_mandate_id = ?",
    );
    expect(clear.values.every((v) => v === LEGACY_199)).toBe(true);
  });

  it("7e: subscription.paused runs the shared park, scoped to trialing/active", async () => {
    fakePhonePe();
    const { db } = await deliver(stateEvent("subscription.paused", HSR_99, "PAUSED"), () => undefined);
    expect(order(db)).toEqual(["park"]);
    const park = db.ran(PARK)[0];
    expect(park.values).toEqual(["paused", HSR_99]);
    expect(park.text).toContain(
      "WHERE (s.merchant_subscription_id = ?) AND prior.id = s.id AND (s.status IN ('trialing', 'active'))",
    );
    expect(reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });

  it("a settled ₹99 debit stamps paid_paise from the debited mandate's own price", async () => {
    fakePhonePe();
    const { db } = await deliver(
      {
        event: "subscription.redemption.order.completed",
        payload: {
          merchantId: "HSRUTILITYONLINE",
          merchantOrderId: HSR_R,
          orderId: "OMO_R",
          state: "COMPLETED",
          paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: HSR_99 },
        },
      },
      (t) =>
        SETTLE.test(t)
          ? [{ user_id: USER_ID, prior_status: "trialing", prior_mandate_id: HSR_99, price_paise: "9900" }]
          : undefined,
    );
    const settle = db.ran(SETTLE)[0];
    expect(settle.text).toContain(
      "paid_paise = s.paid_paise + CASE WHEN s.merchant_subscription_id = ? THEN s.price_paise " +
        "ELSE COALESCE(s.superseded_price_paise, ?) END",
    );
    expect(settle.text).toContain("offer_switch = false");
    expect(settle.text).not.toContain("19900");
    expect(reportPostHogFirstConversion).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ amountPaise: 9900, merchantSubId: HSR_99 }),
    );
  });
});

describe("POST /payments/status — the grant and release surfaces", () => {
  const pendingSwitch: J = {
    id: "row-1",
    user_id: USER_ID,
    status: "pending",
    merchant_subscription_id: HSR_99,
    merchant_order_id: HSR_99_ORDER,
    superseded_mandate_id: LEGACY_199,
    trial_end: ago(40 * DAY),
    current_period_end: ahead(20 * DAY),
    price_paise: "9900",
  };

  it("COMPLETED switches through the shared grant, answers the ₹99 row and revokes the ₹199 after", async () => {
    const { calls } = fakePhonePe({
      order: () => ({
        state: "COMPLETED",
        paymentFlow: { type: "SUBSCRIPTION_SETUP", subscriptionId: "OMS_99" },
      }),
    });
    let reads = 0;
    const { body, db } = await call(
      handleStatus,
      (t) => {
        if (STATUS_READ.test(t)) {
          reads += 1;
          return [
            reads === 1
              ? { ...pendingSwitch }
              : { ...pendingSwitch, status: "active", superseded_mandate_id: null },
          ];
        }
        if (SWITCH.test(t))
          return [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 }];
        return undefined;
      },
      { token },
    );

    expect(body?.status).toBe("active");
    expect(body?.subscription).toMatchObject({ price_paise: 9900 });
    expect(order(db).slice(0, 3)).toEqual([expect.any(String), "switch", expect.any(String)]);
    const sw = db.ran(SWITCH)[0];
    expect(sw.text).toContain("WHERE (s.user_id = ?)");
    expect(sw.values).toEqual(["OMS_99", "25 hours", "25 hours", "25 hours", USER_ID]);
    expect(db.ran(GRANT)).toEqual([]);
    expect(grantReferralReward).not.toHaveBeenCalled();
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
    expect(calls.filter((c) => c.path.endsWith("/status")).map((c) => c.merchant)).toEqual(["hsr", "hsr"]);
  });

  it.each([["FAILED"], ["EXPIRED"]])(
    "%s releases through the shared release and answers the restored ₹199",
    async (state) => {
      const { calls } = fakePhonePe({ order: () => ({ state }) });
      let reads = 0;
      const { body, db } = await call(
        handleStatus,
        (t) => {
          if (STATUS_READ.test(t)) {
            reads += 1;
            return [
              reads === 1
                ? { ...pendingSwitch }
                : {
                    ...pendingSwitch,
                    status: "active",
                    merchant_subscription_id: LEGACY_199,
                    superseded_mandate_id: null,
                    price_paise: "19900",
                  },
            ];
          }
          if (RELEASE.test(t))
            return [{ user_id: USER_ID, status: "active", merchant_subscription_id: LEGACY_199 }];
          return undefined;
        },
        { token },
      );
      expect(db.ran(RELEASE)[0].text).toContain("WHERE (s.user_id = ?) AND prior.id = s.id");
      expect(body?.status).toBe("active");
      expect(body?.subscription).toMatchObject({ merchant_subscription_id: LEGACY_199, price_paise: 19900 });
      expect(calls.map((c) => [c.merchant, c.path])).toEqual([
        ["hsr", `/subscriptions/v2/order/${HSR_99_ORDER}/status`],
        ["legacy", `/subscriptions/v2/${LEGACY_199}/status`],
      ]);
    },
  );
});

describe("POST /payments/cancel — the offer stamp and the extra mandates", () => {
  const liveRow = (patch: J = {}): J => ({
    merchant_subscription_id: LEGACY_199,
    superseded_mandate_id: null,
    offer_mandate_id: null,
    revoke_retry_mandate_id: null,
    status: "active",
    offer_switch: false,
    ...patch,
  });
  const cancel = (row: J, opts: CallOpts = {}) =>
    call(
      handleCancel,
      (t) => {
        if (CANCEL_READ.test(t)) return [row];
        if (CANCEL_WRITE.test(t)) {
          return [
            {
              updated_at: new Date(),
              price_paise: row.price_paise ?? "19900",
              merchant_subscription_id: LEGACY_199,
            },
          ];
        }
        return undefined;
      },
      { token, ...opts },
    );

  it.each([
    ["no body (fielded builds)", { noBody: true }, false],
    ["an empty body", { body: {} }, false],
    ["offer_declined: true", { body: { offer_declined: true } }, true],
    ["offer_declined: 'yes'", { body: { offer_declined: "yes" } }, false],
  ])("%s -> stamps users.cancel_offer_at only on the explicit decline", async (_why, opts, stamped) => {
    fakePhonePe();
    const { res, db } = await cancel(liveRow(), opts);
    expect(res.status).toBe(200);
    const write = db.ran(CANCEL_WRITE)[0];
    expect(write.text).toContain(
      "stamp AS ( UPDATE users SET cancel_offer_at = COALESCE(users.cancel_offer_at, now()) " +
        "WHERE users.id = ? AND ?::boolean AND EXISTS (SELECT 1 FROM c) )",
    );
    expect(write.values).toEqual([19900, true, true, USER_ID, USER_ID, stamped]);
  });

  it("revokes a watched ₹99 and a revoke-retry ₹199 besides the live mandate, each at its merchant", async () => {
    const { calls } = fakePhonePe();
    const { res, db } = await cancel(liveRow({ offer_mandate_id: HSR_99, revoke_retry_mandate_id: OLD_99 }));
    expect(res.status).toBe(200);
    expect(revokes(calls)).toEqual([
      ["legacy", LEGACY_199],
      ["hsr", HSR_99],
      ["hsr", OLD_99],
    ]);
    const write = db.ran(CANCEL_WRITE)[0];
    expect(write.text).toContain(
      "offer_mandate_id = CASE WHEN s.offer_switch THEN s.merchant_subscription_id WHEN ?::boolean THEN NULL " +
        "ELSE s.offer_mandate_id END",
    );
    expect(write.text).toContain(
      "revoke_retry_mandate_id = CASE WHEN ?::boolean THEN NULL ELSE s.revoke_retry_mandate_id END",
    );
    expect(write.values.slice(1, 3)).toEqual([true, true]);
  });

  it("the extra mandates are best effort: one PhonePe keeps live stays on the row, the cancel still succeeds", async () => {
    fakePhonePe({ cancel: (id) => (id === HSR_99 ? refuseCancel() : undefined) });
    const { res, db } = await cancel(liveRow({ offer_mandate_id: HSR_99 }));
    expect(res.status).toBe(200);
    expect(db.ran(CANCEL_WRITE)[0].values.slice(1, 3)).toEqual([false, true]);
  });

  describe("mid-switch", () => {
    const midSwitch = liveRow({
      status: "pending",
      offer_switch: true,
      merchant_subscription_id: HSR_99,
      superseded_mandate_id: LEGACY_199,
      price_paise: "9900",
    });

    it("revokes the parked ₹199 (required) and the unapproved ₹99 (best effort), one on each merchant", async () => {
      const { calls } = fakePhonePe();
      const { res, db } = await cancel(midSwitch, { body: { offer_declined: true } });
      expect(res.status).toBe(200);
      expect(revokes(calls)).toEqual([
        ["legacy", LEGACY_199],
        ["hsr", HSR_99],
      ]);
      const write = db.ran(CANCEL_WRITE)[0];
      expect(write.text).toContain(
        "merchant_subscription_id = CASE WHEN s.offer_switch " +
          "THEN COALESCE(s.superseded_mandate_id, s.merchant_subscription_id) ELSE s.merchant_subscription_id END",
      );
      expect(write.text).toContain(
        "price_paise = CASE WHEN s.offer_switch AND s.superseded_mandate_id IS NOT NULL " +
          "THEN COALESCE(s.superseded_price_paise, ?) ELSE s.price_paise END",
      );
      expect(write.text).toContain("offer_switch = false");
      expect(reportPostHogSubscriptionCancel).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({ merchantSubId: LEGACY_199, reason: "user_cancel" }),
      );
    });

    it("an unapproved ₹99 PhonePe refuses to revoke does not block the cancel", async () => {
      fakePhonePe({ cancel: (id) => (id === HSR_99 ? refuseCancel() : undefined) });
      const { res, db } = await cancel(midSwitch);
      expect(res.status).toBe(200);
      expect(db.ran(CANCEL_WRITE)).toHaveLength(1);
    });

    it("a parked ₹199 PhonePe keeps live is a 502 and nothing is written", async () => {
      const { calls } = fakePhonePe({ cancel: (id) => (id === LEGACY_199 ? refuseCancel() : undefined) });
      const { res, body, db } = await cancel(midSwitch);
      expect(res.status).toBe(502);
      expect(errorCode(body)).toBe("phonepe_error");
      expect(db.ran(CANCEL_WRITE)).toEqual([]);
      expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
    });
  });
});

describe("POST /payments/abandon — an offer switch released on the spot", () => {
  const abandon = (orderState: string) => {
    fakePhonePe({ order: () => ({ state: orderState }) });
    return call(
      handleAbandon,
      (t) => {
        if (ABANDON_READ.test(t)) return [{ status: "pending", merchant_subscription_id: HSR_99 }];
        if (RELEASE.test(t)) {
          return [
            {
              user_id: USER_ID,
              status: "active",
              merchant_subscription_id: LEGACY_199,
              released_mandate_id: HSR_99,
              was_offer: true,
            },
          ];
        }
        return undefined;
      },
      { token, body: { merchantOrderId: HSR_99_ORDER } },
    );
  };

  it("an open order releases the claim to the parked ₹199 and revokes the ₹99 at hsr", async () => {
    const { body, db } = await abandon("PENDING");
    expect(body).toEqual({ abandoned: true, settled: false });
    const release = db.ran(RELEASE)[0];
    expect(release.text).toContain("WHERE (s.user_id = ? AND s.merchant_order_id = ?) AND prior.id = s.id");
    expect(release.values).toEqual([19900, USER_ID, HSR_99_ORDER]);
    expect(revokes(pp.calls)).toEqual([["hsr", HSR_99]]);
  });

  it("a COMPLETED order is settled, never released", async () => {
    const { body, db } = await abandon("COMPLETED");
    expect(body).toEqual({ abandoned: false, settled: true });
    expect(db.ran(RELEASE)).toEqual([]);
  });
});

describe("GET /me and /me/subscription — price and eligibility", () => {
  const ME = /^SELECT u\.id, u\.display_name/;
  const meRow = (patch: J = {}): J => ({
    id: USER_ID,
    display_name: "N",
    email: "n@example.com",
    referral_code: "CODE",
    sub_id: "row-1",
    sub_user_id: USER_ID,
    sub_status: "trialing",
    sub_price_paise: "19900",
    sub_cancel_offer_eligible: true,
    premium: true,
    ...patch,
  });

  it("the eligibility fragment rides the same read, NULL-safe for a user with no row", async () => {
    const { db, body } = await call(handleMe, (t) => (ME.test(t) ? [meRow()] : undefined), { token });
    const read = db.stmts[0];
    expect(read.text).toContain("s.price_paise AS sub_price_paise");
    expect(read.text).toMatch(
      /COALESCE\(\(\( s\.status IN \('trialing', 'active'\)[\s\S]*\)\), false\) AS sub_cancel_offer_eligible/,
    );
    expect(read.text).toContain("u.cancel_offer_at IS NULL");
    expect(body?.subscription).toMatchObject({ price_paise: 19900, cancel_offer_eligible: true });
  });

  it.each([
    [{ sub_price_paise: "9900", sub_cancel_offer_eligible: false }, 9900, false],
    [{ sub_price_paise: null, sub_cancel_offer_eligible: null }, 19900, false],
    [{ sub_cancel_offer_eligible: "t" }, 19900, false],
  ])("%j -> price %s, eligible %s", async (patch, price, eligibleOut) => {
    const { body } = await call(handleMe, (t) => (ME.test(t) ? [meRow(patch)] : undefined), { token });
    expect(body?.subscription).toMatchObject({ price_paise: price, cancel_offer_eligible: eligibleOut });
  });

  it("/me/subscription carries the same two keys through an inner join on users", async () => {
    const { db, body } = await call(
      handleMeSubscription,
      () => [
        {
          id: "row-1",
          user_id: USER_ID,
          status: "active",
          price_paise: "9900",
          cancel_offer_eligible: false,
        },
      ],
      { token },
    );
    expect(db.stmts[0].text).toContain("FROM subscriptions AS s JOIN users AS u ON u.id = s.user_id");
    expect(db.stmts[0].text).toContain("AS cancel_offer_eligible");
    expect(body).toMatchObject({ price_paise: 9900, cancel_offer_eligible: false });
  });
});

describe("the offer survives account deletion", () => {
  const TOMB = /^INSERT INTO trial_tombstones/;

  it("DELETE /me writes the spent offer onto the tombstone and revokes the extra mandates best effort", async () => {
    const { calls } = fakePhonePe({ cancel: (id) => (id === LEGACY_199 ? refuseCancel() : undefined) });
    const spentAt = ago(5 * DAY);
    const trialEnd = ago(30 * DAY);
    const { res, db } = await call(
      handleDeleteAccount,
      (t) =>
        t.startsWith("SELECT u.google_sub")
          ? [
              {
                google_sub: "g-sub",
                cancel_offer_at: spentAt,
                status: "cancelled",
                merchant_subscription_id: HSR_99,
                superseded_mandate_id: null,
                offer_mandate_id: OLD_99,
                revoke_retry_mandate_id: LEGACY_199,
                trial_end: trialEnd,
                price_paise: "9900",
              },
            ]
          : undefined,
      { token },
    );

    expect(res.status).toBe(200);
    expect(revokes(calls)).toEqual([
      ["hsr", OLD_99],
      ["legacy", LEGACY_199],
    ]);
    const tomb = db.ran(TOMB)[0];
    expect(tomb.text).toContain("INSERT INTO trial_tombstones (google_sub_hash, trial_end, cancel_offer_at)");
    expect(tomb.text).toContain(
      "ON CONFLICT (google_sub_hash) DO UPDATE SET trial_end = COALESCE(trial_tombstones.trial_end, EXCLUDED.trial_end), " +
        "cancel_offer_at = COALESCE(trial_tombstones.cancel_offer_at, EXCLUDED.cancel_offer_at)",
    );
    expect(tomb.values).toEqual([expect.stringMatching(/^[0-9a-f]{64}$/), trialEnd, spentAt]);
    expect(db.ran(/^DELETE FROM users WHERE id = \?/)).toHaveLength(1);
  });

  it("an unspent offer writes a NULL stamp", async () => {
    fakePhonePe();
    const { db } = await call(
      handleDeleteAccount,
      (t) =>
        t.startsWith("SELECT u.google_sub")
          ? [{ google_sub: "g-sub", cancel_offer_at: null, status: "expired", trial_end: ago(DAY) }]
          : undefined,
      { token },
    );
    expect(db.ran(TOMB)[0].values[2]).toBeNull();
  });

  it("/auth/login pre-seeds users.cancel_offer_at from the tombstone in the same statement, new rows only", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "g-sub",
      email: "g@example.com",
      email_verified: true,
      name: "G",
      nonce: undefined,
    } as Awaited<ReturnType<typeof verifyGoogleIdToken>>);
    const { res, db } = await call(
      handleLogin,
      (t) =>
        t.includes("INSERT INTO users")
          ? [
              {
                id: USER_ID,
                display_name: "G",
                referral_code: "CODE",
                inserted: true,
                tomb_trial_end: ago(DAY),
              },
            ]
          : undefined,
      { body: { idToken: "valid" } },
    );

    expect(res.status).toBe(200);
    const upsert = db.ran("INSERT INTO users")[0].text;
    expect(upsert).toContain("WITH tomb AS ( SELECT trial_end, cancel_offer_at FROM trial_tombstones");
    expect(upsert).toContain(
      "INSERT INTO users (google_sub, email, display_name, referral_code, cancel_offer_at) " +
        "VALUES (?, ?, ?, ?, (SELECT cancel_offer_at FROM tomb))",
    );
    const onConflict = upsert.slice(
      upsert.indexOf("ON CONFLICT (google_sub) DO UPDATE"),
      upsert.indexOf("RETURNING"),
    );
    expect(onConflict).not.toContain("cancel_offer_at");
  });
});
