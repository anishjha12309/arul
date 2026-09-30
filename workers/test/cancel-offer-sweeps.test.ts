/**
 * The top-of-hour sweeps (cron/autopay-sweeps.ts) and the cron's price plumbing for the ₹99 cancel-save offer.
 * There is no Postgres here -> assertions read SQL text, bound values and statement order, and lib/phonepe.ts runs
 * for real against a stub that names the merchant each call authenticated as
 */

import { afterEach, describe, expect, it, vi } from "vitest";
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
import { merchantOf } from "../src/lib/phonepe.js";
import { reportPostHogFirstConversion, reportPostHogSubscriptionCancel } from "../src/lib/posthog.js";
import { grantReferralReward } from "../src/lib/referral.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const LEGACY_199 = "DKS_S_550E8400_MFX1K2A0";
const HSR_99 = "DKS_HS_550E8400_MG2B7Q10";
const HSR_NEW = "DKS_HS_550E8400_MG3C0000";
const HSR_NEW_ORDER = "DKS_HS_550E8400_MG3C0000_0A0B";
const LEGACY_R = "DKS_R_550E8400_MG9C1D00_7F3A";
const HSR_R = "DKS_HR_550E8400_MGAB0000_0C1D";
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const ago = (ms: number) => new Date(Date.now() - ms);
// Minted `ms` ago the way buildMerchantSubscriptionId mints -> mandateCreatedAt reads the age back
const mintedAgo = (ms: number) => `DKS_HS_550E8400_${(Date.now() - ms).toString(36).toUpperCase()}`;

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

const HEAL_SELECT = /^SELECT id, redemption_order_id, status FROM subscriptions/;
const CLAIMS_SELECT = /^SELECT id, user_id, merchant_subscription_id, merchant_order_id, offer_switch/;
const OFFERS_SELECT = /^SELECT id, offer_mandate_id FROM subscriptions/;
const RETRY_SELECT = /^SELECT s\.id, s\.revoke_retry_mandate_id/;
const LEGACY_SELECT =
  /^SELECT id, merchant_subscription_id FROM subscriptions WHERE status IN \('trialing', 'active'\)/;
const RELEASE = /AS released_mandate_id/;
const SWITCH = /^WITH g AS \( UPDATE subscriptions AS s SET status = CASE/;
const HONOUR = /^WITH g AS \( UPDATE subscriptions AS s SET merchant_subscription_id = s\.offer_mandate_id/;
const GRANT = /AND s\.status = 'pending' AND NOT s\.offer_switch/;
const HEAL_CANDIDATE =
  /^SELECT COALESCE\(s\.superseded_mandate_id, s\.merchant_subscription_id\) AS mandate_id/;
const HEAL = /^UPDATE subscriptions AS s SET status = \?, merchant_subscription_id = COALESCE/;
const NOTE_RETRY = /^UPDATE subscriptions SET revoke_retry_mandate_id = \?/;
const PARK = /^UPDATE subscriptions AS s SET status = \?, next_debit_at = NULL, notified_at = NULL/;
const CLEAR_ORDER =
  /^UPDATE subscriptions SET redemption_order_id = NULL, notified_at = NULL WHERE id = \? AND redemption_order_id = \?/;
const CLEAR_OFFER =
  /^UPDATE subscriptions SET offer_mandate_id = NULL WHERE id = \? AND offer_mandate_id = \?/;
const CLEAR_RETRY = /^UPDATE subscriptions SET revoke_retry_mandate_id = NULL WHERE id = \?/;
const TOUCH =
  /^UPDATE subscriptions SET updated_at = now\(\) WHERE id = \? AND status IN \('trialing', 'active'\)/;
const PASS_A = /^SELECT id, user_id, merchant_subscription_id, next_debit_at, debit_count/;
const PASS_B = /^SELECT id, user_id, status, merchant_subscription_id, redemption_order_id/;
const PASS_D = /^SELECT id, merchant_subscription_id FROM subscriptions WHERE status = 'paused'/;
const IDLE = /min\(next_debit_at\)/;
const SETTLE = /^UPDATE subscriptions SET status = 'active', current_period_end = \?/;
const REARM = /^UPDATE subscriptions SET status = CASE WHEN trial_end IS NOT NULL/;

const LABELS: [string, RegExp][] = [
  ["heal-select", HEAL_SELECT],
  ["claims-select", CLAIMS_SELECT],
  ["offers-select", OFFERS_SELECT],
  ["retries-select", RETRY_SELECT],
  ["legacy-select", LEGACY_SELECT],
  ["release", RELEASE],
  ["switch", SWITCH],
  ["honour", HONOUR],
  ["grant", GRANT],
  ["heal-candidate", HEAL_CANDIDATE],
  ["heal", HEAL],
  ["note-retry", NOTE_RETRY],
  ["park", PARK],
  ["clear-order", CLEAR_ORDER],
  ["clear-offer", CLEAR_OFFER],
  ["clear-retry", CLEAR_RETRY],
  ["touch", TOUCH],
  ["pass-a", PASS_A],
  ["pass-b", PASS_B],
  ["pass-d", PASS_D],
  ["idle", IDLE],
  ["settle", SETTLE],
  ["rearm", REARM],
];
const order = (db: ReturnType<typeof routedSql>) =>
  db.stmts.map((s) => LABELS.find(([, re]) => re.test(s.text))?.[0] ?? s.text.slice(0, 40));
const SELECTS = ["heal-select", "claims-select", "offers-select", "retries-select", "legacy-select"];

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
  redeem?: (orderId: string) => J | undefined;
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
      if (path === "/subscriptions/v2/notify") {
        return Response.json({ orderId: "OMO_N", state: "NOTIFIED", expireAt: Date.now() + DAY });
      }
      if (path === "/subscriptions/v2/redeem") {
        return Response.json(
          script.redeem?.(String(body?.merchantOrderId)) ?? { state: "PENDING", transactionId: "TXN" },
        );
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
const reads = (calls: PpCall[]) =>
  calls.filter((c) => c.path.endsWith("/status")).map((c) => [c.merchant, c.path.split("/").at(-2)]);

const refuseCancel = () => new Response('{"code":"BAD_REQUEST"}', { status: 400 });
const notFound = (code: string) => new Response(JSON.stringify({ code }), { status: 400 });

function dualEnv(overrides: Record<string, unknown> = {}): Env {
  return makeEnv({
    PHONEPE_MERCHANT_ID: "AUTOGRAMAPPSONLINE",
    PHONEPE_CLIENT_ID: "legacy-client",
    PHONEPE_CLIENT_SECRET: "legacy-secret",
    PHONEPE_HSR_MERCHANT_ID: "HSRUTILITYONLINE",
    PHONEPE_HSR_CLIENT_ID: "hsr-client",
    PHONEPE_HSR_CLIENT_SECRET: "hsr-secret",
    PHONEPE_HSR_CLIENT_VERSION: "1",
    PHONEPE_SETUP_MERCHANT: "hsr",
    ...overrides,
  });
}

interface Books {
  heal?: unknown[];
  claims?: unknown[];
  offers?: unknown[];
  retries?: unknown[];
  legacy?: unknown[];
}

async function sweep(
  books: Books,
  route: Route = () => undefined,
  take: (calls: number) => boolean = () => true,
) {
  const db = routedSql((t, v) => {
    const answer = route(t, v);
    if (answer !== undefined) return answer;
    if (HEAL_SELECT.test(t)) return books.heal;
    if (CLAIMS_SELECT.test(t)) return books.claims;
    if (OFFERS_SELECT.test(t)) return books.offers;
    if (RETRY_SELECT.test(t)) return books.retries;
    if (LEGACY_SELECT.test(t)) return books.legacy;
    return undefined;
  });
  const budget = { take: vi.fn(take) };
  await runHourlySweeps(dualEnv(), db.sql as never, budget);
  return { db, budget };
}

afterEach(() => {
  expectOneMerchantPerCall(pp.calls);
  pp = { calls: [] };
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  vi.useRealTimers();
});

describe("runHourlySweeps — five passes, one budget", () => {
  it("runs heal, claims, offer mandates, revoke retries and the legacy reconcile, in that order", async () => {
    fakePhonePe();
    const { db } = await sweep({});
    expect(order(db)).toEqual(SELECTS);

    const [heal, claims, , , legacy] = db.stmts;
    expect(heal.text).toContain("WHERE status IN ('pending', 'cancelled', 'expired', 'paused')");
    expect(heal.text).toContain(
      "AND trial_end IS NOT NULL AND (current_period_end IS NULL OR current_period_end <= trial_end) " +
        "AND NOT (status = 'pending' AND updated_at > now() - ?::interval)",
    );
    expect(heal.values).toEqual(["30 minutes", 100]);
    expect(claims.text).toContain("WHERE status = 'pending' AND updated_at < now() - ?::interval");
    expect(claims.values).toEqual(["30 minutes", 300]);
    expect(legacy.text).toContain("AND left(merchant_subscription_id, 5) <> 'DKS_H'");
  });

  it("reserves each pass's calls per row before any await, and a refusal leaves every row untouched", async () => {
    fakePhonePe();
    const { db, budget } = await sweep(
      {
        heal: [{ id: "h1", redemption_order_id: LEGACY_R, status: "cancelled" }],
        claims: [{ id: "c1", merchant_order_id: HSR_NEW_ORDER, updated_at: ago(HOUR) }],
        offers: [{ id: "o1", offer_mandate_id: HSR_99 }],
        retries: [{ id: "r1", revoke_retry_mandate_id: LEGACY_199, cancel_offer_at: ago(DAY) }],
        legacy: [{ id: "l1", merchant_subscription_id: LEGACY_199 }],
      },
      () => undefined,
      () => false,
    );
    expect(budget.take.mock.calls.map(([n]) => n)).toEqual([3, 4, 4, 3, 1]);
    expect(order(db)).toEqual(SELECTS);
    expect(pp.calls).toEqual([]);
  });
});

describe("7a — stale pending claims", () => {
  const claim = (patch: J = {}): J => ({
    id: "c1",
    user_id: USER_ID,
    merchant_subscription_id: HSR_NEW,
    merchant_order_id: HSR_NEW_ORDER,
    offer_switch: false,
    trial_end: null,
    updated_at: ago(40 * MIN),
    ...patch,
  });
  const completed = (doneAgoMs: number): J => ({
    state: "COMPLETED",
    paymentFlow: { type: "SUBSCRIPTION_SETUP", subscriptionId: "OMS_NEW" },
    paymentDetails: [{ state: "COMPLETED", timestamp: Date.now() - doneAgoMs }],
  });
  const without = (db: ReturnType<typeof routedSql>) => order(db).filter((l) => !SELECTS.includes(l));

  it.each([["FAILED"], ["EXPIRED"]])("%s -> released by id through the shared release", async (state) => {
    const { calls } = fakePhonePe({ order: () => ({ state }) });
    const { db } = await sweep({ claims: [claim()] });
    expect(without(db)).toEqual(["release"]);
    const release = db.ran(RELEASE)[0];
    expect(release.text).toContain("WHERE (s.id = ?) AND prior.id = s.id AND s.status = 'pending'");
    expect(release.values).toEqual([19900, "c1"]);
    expect(reads(calls)).toEqual([["hsr", HSR_NEW_ORDER]]);
  });

  it("an order PhonePe never created -> released", async () => {
    fakePhonePe({ order: () => notFound("ORDER_NOT_FOUND") });
    const { db } = await sweep({ claims: [claim()] });
    expect(without(db)).toEqual(["release"]);
  });

  it("a claim with no setup order -> released without a PhonePe call", async () => {
    fakePhonePe();
    const { db } = await sweep({ claims: [claim({ merchant_order_id: null })] });
    expect(without(db)).toEqual(["release"]);
    expect(pp.calls).toEqual([]);
  });

  it("a failed order read -> nothing is written", async () => {
    fakePhonePe({ order: () => new Response("down", { status: 503 }) });
    const { db } = await sweep({ claims: [claim()] });
    expect(without(db)).toEqual([]);
  });

  it("COMPLETED -> the shared grant (switch first), with PhonePe's subscription id", async () => {
    fakePhonePe({ order: () => completed(35 * MIN) });
    const { db } = await sweep({ claims: [claim()] }, (t) =>
      GRANT.test(t)
        ? [{ user_id: USER_ID, status: "trialing", price_paise: 19900, stale_mandate_id: null }]
        : undefined,
    );
    expect(without(db)).toEqual(["switch", "grant"]);
    expect(db.ran(SWITCH)[0].values).toEqual(["OMS_NEW", "25 hours", "25 hours", "25 hours", "c1"]);
    expect(db.ran(GRANT)[0].values[0]).toBe("OMS_NEW");
    expect(grantReferralReward).not.toHaveBeenCalled();
  });

  it("a COMPLETED ₹199 TRANSACTION grants 'active' with the referral reward, however late", async () => {
    fakePhonePe({ order: () => completed(30 * HOUR) });
    await sweep({ claims: [claim({ trial_end: ago(40 * DAY), updated_at: ago(31 * HOUR) })] }, (t) =>
      GRANT.test(t)
        ? [{ user_id: USER_ID, status: "active", price_paise: 19900, stale_mandate_id: null }]
        : undefined,
    );
    expect(grantReferralReward).toHaveBeenCalledTimes(1);
  });

  it("a COMPLETED cancel_99 switches and revokes the parked ₹199 at its own merchant", async () => {
    const { calls } = fakePhonePe({ order: () => completed(35 * MIN) });
    const { db } = await sweep(
      { claims: [claim({ merchant_subscription_id: HSR_99, offer_switch: true })] },
      (t) =>
        SWITCH.test(t)
          ? [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 }]
          : undefined,
    );
    expect(without(db)).toEqual(["switch"]);
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
    expect(grantReferralReward).not.toHaveBeenCalled();
  });

  it("a switch whose ₹199 PhonePe will not revoke notes it for the retry pass", async () => {
    fakePhonePe({ order: () => completed(35 * MIN), cancel: refuseCancel });
    const { db } = await sweep({ claims: [claim({ offer_switch: true })] }, (t) =>
      SWITCH.test(t)
        ? [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 }]
        : undefined,
    );
    expect(without(db)).toEqual(["switch", "note-retry"]);
    expect(db.ran(NOTE_RETRY)[0].values).toEqual([LEGACY_199, USER_ID]);
  });

  it.each([
    ["a trial's ₹2 check", { trial_end: null }],
    [
      "a cancel_99 ₹2 check",
      { offer_switch: true, merchant_subscription_id: HSR_99, trial_end: ago(40 * DAY) },
    ],
  ])("%s approved over 24 h ago -> revoked and released, never granted", async (_why, patch) => {
    const { calls } = fakePhonePe({ order: () => completed(30 * HOUR) });
    const row = claim({ ...patch, updated_at: ago(31 * HOUR) });
    const { db } = await sweep({ claims: [row] });
    expect(without(db)).toEqual(["release"]);
    expect(revokes(calls)).toEqual([["hsr", row.merchant_subscription_id]]);
  });

  it("a late ₹2 check PhonePe will not revoke stays pending for the next hour", async () => {
    fakePhonePe({ order: () => completed(30 * HOUR), cancel: refuseCancel });
    const { db } = await sweep({ claims: [claim({ updated_at: ago(31 * HOUR) })] });
    expect(without(db)).toEqual([]);
  });

  it("an order still open inside 2 h is left alone; past 2 h it is revoked and released", async () => {
    fakePhonePe();
    const young = await sweep({ claims: [claim({ updated_at: ago(90 * MIN) })] });
    expect(without(young.db)).toEqual([]);
    expect(revokes(pp.calls)).toEqual([]);

    const { calls } = fakePhonePe();
    const old = await sweep({ claims: [claim({ updated_at: ago(3 * HOUR) })] });
    expect(without(old.db)).toEqual(["release"]);
    expect(revokes(calls)).toEqual([["hsr", HSR_NEW]]);
  });
});

describe("7b — a settled debit on a row outside the cron's reach", () => {
  const healed = {
    user_id: USER_ID,
    status: "active",
    merchant_subscription_id: LEGACY_199,
    price_paise: "19900",
  };
  const healRoute =
    (row: J = { ...healed, prior_mandate_id: LEGACY_199 }): Route =>
    (t) => {
      if (HEAL_CANDIDATE.test(t)) return [{ mandate_id: LEGACY_199 }];
      if (HEAL.test(t)) return [row];
      return undefined;
    };
  const without = (db: ReturnType<typeof routedSql>) => order(db).filter((l) => !SELECTS.includes(l));

  it.each([["pending"], ["cancelled"], ["expired"], ["paused"]])(
    "COMPLETED on a %s row -> healed once",
    async (status) => {
      const { calls } = fakePhonePe({ order: () => ({ state: "COMPLETED" }) });
      const { db } = await sweep(
        { heal: [{ id: "h1", redemption_order_id: LEGACY_R, status }] },
        healRoute(),
      );
      expect(without(db)).toEqual(["heal-candidate", "heal"]);
      const heal = db.ran(HEAL)[0];
      expect(heal.text).toContain("WHERE (s.id = ?) AND prior.id = s.id AND s.redemption_order_id = ?");
      expect(heal.values.slice(-2)).toEqual(["h1", LEGACY_R]);
      expect(reads(calls)).toEqual([
        ["legacy", LEGACY_R],
        ["legacy", LEGACY_199],
      ]);
      expect(grantReferralReward).toHaveBeenCalledTimes(1);
      expect(reportPostHogFirstConversion).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({ transactionId: LEGACY_R, amountPaise: 19900 }),
      );
    },
  );

  it("a heal handing the row back to its parked mandate revokes the unapproved one at its merchant", async () => {
    const { calls } = fakePhonePe({ order: () => ({ state: "COMPLETED" }) });
    await sweep(
      { heal: [{ id: "h1", redemption_order_id: LEGACY_R, status: "pending" }] },
      healRoute({ ...healed, prior_mandate_id: HSR_99 }),
    );
    expect(revokes(calls)).toEqual([["hsr", HSR_99]]);
  });

  it.each([
    ["FAILED", { state: "FAILED" }],
    ["open past its own expireAt", { state: "NOTIFIED", expireAt: Date.now() - HOUR }],
    ["never created", notFound("ORDER_NOT_FOUND")],
  ])("an order %s is dropped from the row so it is not re-read forever", async (_why, answer) => {
    fakePhonePe({ order: () => answer });
    const { db } = await sweep({ heal: [{ id: "h1", redemption_order_id: HSR_R, status: "cancelled" }] });
    expect(without(db)).toEqual(["clear-order"]);
    expect(db.ran(CLEAR_ORDER)[0].values).toEqual(["h1", HSR_R]);
  });

  it.each([
    ["still open", { state: "PENDING" }],
    ["unreadable", new Response("down", { status: 503 })],
  ])("an order %s changes nothing", async (_why, answer) => {
    fakePhonePe({ order: () => answer });
    const { db } = await sweep({ heal: [{ id: "h1", redemption_order_id: HSR_R, status: "cancelled" }] });
    expect(without(db)).toEqual([]);
  });

  describe("a stranded claim made inside its parked mandate's notify window", () => {
    // The claim's upsert and releaseClaim never touch notified_at, so the parked ₹199's notice rides the pending row
    const stranded = async () => {
      fakePhonePe({
        order: (id) =>
          id === LEGACY_R ? { state: "NOTIFIED", expireAt: Date.now() - HOUR } : { state: "EXPIRED" },
      });
      return sweep(
        {
          heal: [{ id: "c1", redemption_order_id: LEGACY_R, status: "pending" }],
          claims: [
            {
              id: "c1",
              user_id: USER_ID,
              merchant_subscription_id: HSR_NEW,
              merchant_order_id: HSR_NEW_ORDER,
              offer_switch: false,
              trial_end: ago(40 * DAY),
              updated_at: ago(80 * HOUR),
            },
          ],
        },
        (t) =>
          RELEASE.test(t)
            ? [{ user_id: USER_ID, status: "trialing", merchant_subscription_id: LEGACY_199 }]
            : undefined,
      );
    };

    it("7b drops its dead redemption order, then 7a hands the row back to the parked ₹199, in one tick", async () => {
      const { db } = await stranded();
      expect(without(db)).toEqual(["clear-order", "release"]);
    });

    // Pass A selects only notified_at IS NULL and Pass B skips a row with no redemption_order_id -> neither bills it
    it("the released row must not keep notified_at with no order behind it", async () => {
      const { db } = await stranded();
      const writes = [...db.ran(CLEAR_ORDER), ...db.ran(RELEASE)];
      expect(writes.some((w) => /\bnotified_at = (NULL|CASE)/.test(w.text))).toBe(true);
    });
  });
});

describe("4h — a released switch's ₹99 watched for a late approval", () => {
  const honoured = { user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 };
  const without = (db: ReturnType<typeof routedSql>) => order(db).filter((l) => !SELECTS.includes(l));

  it("late ACTIVE on a row still on its ₹199 -> switched, the ₹199 revoked at its own merchant", async () => {
    const { calls } = fakePhonePe();
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] }, (t) =>
      HONOUR.test(t) ? [honoured] : undefined,
    );
    expect(without(db)).toEqual(["honour"]);
    expect(db.ran(HONOUR)[0].values).toEqual([
      "OMS_LIVE",
      9900,
      "25 hours",
      "25 hours",
      "25 hours",
      HSR_99,
      19900,
    ]);
    expect(reads(calls)).toEqual([["hsr", HSR_99]]);
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
  });

  it("a switched ₹199 PhonePe will not revoke is noted for retry", async () => {
    fakePhonePe({ cancel: refuseCancel });
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] }, (t) =>
      HONOUR.test(t) ? [honoured] : undefined,
    );
    expect(without(db)).toEqual(["honour", "note-retry"]);
  });

  it("late ACTIVE on a row no longer eligible -> the ₹99 is revoked and unwatched, never granted", async () => {
    const { calls } = fakePhonePe();
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] });
    expect(without(db)).toEqual(["honour", "clear-offer"]);
    expect(db.ran(CLEAR_OFFER)[0].values).toEqual(["o1", HSR_99]);
    expect(revokes(calls)).toEqual([["hsr", HSR_99]]);
  });

  it("an ACTIVE ₹99 PhonePe will not revoke stays watched", async () => {
    fakePhonePe({ cancel: refuseCancel });
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] });
    expect(without(db)).toEqual(["honour"]);
  });

  it.each([["REVOKED"], ["CANCELLED"], ["EXPIRED"], ["FAILED"]])(
    "%s -> unwatched without a revoke",
    async (state) => {
      fakePhonePe({ mandate: () => state });
      const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] });
      expect(without(db)).toEqual(["clear-offer"]);
      expect(revokes(pp.calls)).toEqual([]);
    },
  );

  it("a ₹99 PhonePe never created -> unwatched", async () => {
    fakePhonePe({ mandate: () => notFound("SUBSCRIPTION_NOT_FOUND") });
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] });
    expect(without(db)).toEqual(["clear-offer"]);
  });

  it("still in progress: watched for 24 h by the id's own timestamp, then revoked and unwatched", async () => {
    const fresh = mintedAgo(HOUR);
    const stale = mintedAgo(30 * HOUR);
    const { calls } = fakePhonePe({ mandate: () => "ACTIVATION_IN_PROGRESS" });
    const { db } = await sweep({
      offers: [
        { id: "o1", offer_mandate_id: fresh },
        { id: "o2", offer_mandate_id: stale },
      ],
    });
    expect(without(db)).toEqual(["clear-offer"]);
    expect(db.ran(CLEAR_OFFER)[0].values).toEqual(["o2", stale]);
    expect(revokes(calls)).toEqual([["hsr", stale]]);
  });

  it("an unreadable ₹99 changes nothing", async () => {
    fakePhonePe({ mandate: () => new Response("down", { status: 503 }) });
    const { db } = await sweep({ offers: [{ id: "o1", offer_mandate_id: HSR_99 }] });
    expect(without(db)).toEqual([]);
  });
});

describe("revoke retries — a ₹199 the switch could not revoke", () => {
  it("a revoke that lands clears the column", async () => {
    const { calls } = fakePhonePe();
    const { db } = await sweep({
      retries: [{ id: "r1", revoke_retry_mandate_id: LEGACY_199, cancel_offer_at: ago(HOUR) }],
    });
    expect(db.ran(CLEAR_RETRY)[0].values).toEqual(["r1", LEGACY_199]);
    expect(revokes(calls)).toEqual([["legacy", LEGACY_199]]);
  });

  it.each([
    [80 * HOUR, true],
    [10 * HOUR, false],
  ])("still refused %s ms after the switch -> kept; ALARM %s", async (sinceMs, alarm) => {
    fakePhonePe({ cancel: refuseCancel });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { db } = await sweep({
      retries: [{ id: "r1", revoke_retry_mandate_id: LEGACY_199, cancel_offer_at: ago(sinceMs) }],
    });
    expect(db.ran(CLEAR_RETRY)).toEqual([]);
    const alarmed = errors.mock.calls.some(([line]) => String(line).includes("ALARM"));
    errors.mockRestore();
    expect(alarmed).toBe(alarm);
  });
});

describe("7i — the legacy merchant's mandates (it sends no webhook)", () => {
  const legacyRow = { id: "l1", merchant_subscription_id: LEGACY_199 };
  const parked = [
    { user_id: USER_ID, merchant_subscription_id: LEGACY_199, price_paise: "19900", prior_status: "active" },
  ];
  const without = (db: ReturnType<typeof routedSql>) => order(db).filter((l) => !SELECTS.includes(l));

  it.each([["REVOKED"], ["CANCELLED"]])(
    "%s -> the shared park, cancelled, reported as revoked_at_phonepe",
    async (state) => {
      const { calls } = fakePhonePe({ mandate: () => state });
      const { db } = await sweep({ legacy: [legacyRow] }, (t) => (PARK.test(t) ? parked : undefined));
      expect(without(db)).toEqual(["park"]);
      expect(db.ran(PARK)[0].values).toEqual(["cancelled", "l1"]);
      expect(reads(calls)).toEqual([["legacy", LEGACY_199]]);
      expect(reportPostHogSubscriptionCancel).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({ reason: "revoked_at_phonepe", priorStatus: "active", pricePaise: 19900 }),
      );
    },
  );

  it("PAUSED -> the shared park, paused, no cancel event", async () => {
    fakePhonePe({ mandate: () => "PAUSED" });
    const { db } = await sweep({ legacy: [legacyRow] });
    expect(without(db)).toEqual(["park"]);
    expect(db.ran(PARK)[0].values).toEqual(["paused", "l1"]);
    expect(db.ran(PARK)[0].text).toContain("(s.status IN ('trialing', 'active'))");
    expect(reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });

  it.each([
    ["ACTIVE", "ACTIVE"],
    ["EXPIRED", "EXPIRED"],
    ["an unreadable mandate", new Response("down", { status: 503 })],
  ])("%s -> only updated_at moves, so the rotation reaches the whole book", async (_why, answer) => {
    fakePhonePe({ mandate: () => answer });
    const { db } = await sweep({ legacy: [legacyRow] });
    expect(without(db)).toEqual(["touch"]);
    expect(db.ran(TOUCH)[0].values).toEqual(["l1"]);
  });
});

describe("runAutopayNotify — the row's price and the hourly wiring", () => {
  const at = (iso: string) => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(iso));
  };

  async function cron(passA: unknown[], passB: unknown[], passD: unknown[], route: Route = () => undefined) {
    const env = dualEnv();
    const db = routedSql((t, v) => {
      const answer = route(t, v);
      if (answer !== undefined) return answer;
      if (IDLE.test(t)) return [{ soonest: null, in_flight: 0 }];
      if (PASS_A.test(t)) return passA;
      if (PASS_B.test(t)) return passB;
      if (PASS_D.test(t)) return passD;
      return undefined;
    });
    (env as unknown as { _testSql: unknown })._testSql = db.sql;
    await runAutopayNotify(env);
    return { db, env };
  }

  const dueForNotify = (id: string, msid: string, price: unknown): J => ({
    id,
    user_id: USER_ID,
    merchant_subscription_id: msid,
    next_debit_at: new Date(Date.now() + 20 * HOUR).toISOString(),
    debit_count: 0,
    current_period_end: new Date(Date.now() + 20 * HOUR).toISOString(),
    price_paise: price,
  });

  it("Pass A notifies each mandate at its row's price, under its own merchant's marker", async () => {
    at("2026-09-30T10:20:00Z");
    const { calls } = fakePhonePe();
    const { db } = await cron(
      [
        dueForNotify("a1", HSR_99, "9900"),
        dueForNotify("a2", LEGACY_199, 19900),
        dueForNotify("a3", LEGACY_199, null),
      ],
      [],
      [],
    );
    expect(db.ran(PASS_A)[0].text).toContain("price_paise FROM subscriptions");
    const notifies = calls.filter((c) => c.path === "/subscriptions/v2/notify");
    expect(
      notifies.map((c) => [
        c.merchant,
        c.body?.amount,
        String(c.body?.merchantOrderId).match(/^DKS_H?R_/)?.[0],
      ]),
    ).toEqual([
      ["hsr", 9900, "DKS_HR_"],
      ["legacy", 19900, "DKS_R_"],
      ["legacy", 19900, "DKS_R_"],
    ]);
  });

  it("a settled ₹99 debit stamps paid_paise from the row and reports ₹99", async () => {
    at("2026-09-30T10:20:00Z");
    fakePhonePe({ redeem: () => ({ state: "COMPLETED", transactionId: "TXN" }) });
    const { db } = await cron(
      [],
      [
        {
          id: "b1",
          user_id: USER_ID,
          status: "trialing",
          merchant_subscription_id: HSR_99,
          redemption_order_id: HSR_R,
          retry_count: 0,
          next_debit_at: new Date(Date.now() - 30 * MIN).toISOString(),
          notified_at: new Date(Date.now() - 25 * HOUR).toISOString(),
          current_period_end: new Date(Date.now() - 30 * MIN).toISOString(),
          upi_target_app: "com.phonepe.app",
          price_paise: "9900",
        },
      ],
      [],
      (t) => (SETTLE.test(t) ? [{ updated_at: new Date() }] : undefined),
    );
    const settle = db.ran(SETTLE)[0];
    expect(settle.text).toContain("paid_paise = paid_paise + price_paise");
    expect(settle.text).not.toContain("19900");
    expect(settle.values).not.toContain(19900);
    expect(reportPostHogFirstConversion).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ transactionId: HSR_R, amountPaise: 9900, merchantSubId: HSR_99 }),
    );
  });

  it("the sweeps run on the top-of-hour tick only, after the debits and Pass D, before the idle marker", async () => {
    at("2026-09-30T10:05:00Z");
    fakePhonePe();
    const top = await cron([], [], []);
    const labels = order(top.db);
    expect(labels.filter((l) => SELECTS.includes(l))).toEqual(SELECTS);
    expect(labels.indexOf("pass-d")).toBeLessThan(labels.indexOf("heal-select"));
    expect(labels.indexOf("legacy-select")).toBeLessThan(labels.indexOf("idle"));

    at("2026-09-30T10:20:00Z");
    const quarter = await cron([], [], []);
    expect(order(quarter.db).filter((l) => SELECTS.includes(l))).toEqual([]);
  });

  it("past the sweep wall clock the passes still select but make no PhonePe call", async () => {
    at("2026-09-30T10:05:00Z");
    fakePhonePe();
    const { db } = await cron([], [], [], (t) => {
      if (PASS_D.test(t)) vi.setSystemTime(new Date(Date.now() + 11 * MIN));
      if (OFFERS_SELECT.test(t)) return [{ id: "o1", offer_mandate_id: HSR_99 }];
      return undefined;
    });
    expect(order(db)).toContain("offers-select");
    expect(pp.calls).toEqual([]);
  });

  it("7d: Pass D rearms an unpaused row through the shared CASE", async () => {
    at("2026-09-30T10:05:00Z");
    const { calls } = fakePhonePe();
    const { db } = await cron([], [], [{ id: "d1", merchant_subscription_id: HSR_99 }]);
    const rearm = db.ran(REARM)[0];
    expect(rearm.text).toContain(
      "SET status = CASE WHEN trial_end IS NOT NULL AND current_period_end > trial_end THEN 'active' ELSE 'trialing' END",
    );
    expect(rearm.values).toEqual(["d1", null]);
    expect(reads(calls)).toEqual([["hsr", HSR_99]]);
  });
});
