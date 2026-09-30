/**
 * The ₹99 cancel-save offer's shared row transitions (lib/subscription-state.ts), read as SQL text and bound values:
 * vitest has no Postgres, the PGlite harness proves the semantics. PostHog and lib/phonepe.ts run for real against a
 * fetch stub that names the merchant each call authenticated as
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

import {
  buildMerchantOrderId,
  buildMerchantSubscriptionId,
  mandateCreatedAt,
  merchantOf,
} from "../src/lib/phonepe.js";
import { reportPostHogFirstConversion, reportPostHogSubscriptionCancel } from "../src/lib/posthog.js";
import { CANCEL_OFFER, OFFER_PRICE_PAISE, STANDARD_PRICE_PAISE, offerOfPrice } from "../src/lib/pricing.js";
import { grantReferralReward } from "../src/lib/referral.js";
import { rearmUnpausedSubscription } from "../src/lib/subscription-rearm.js";
import {
  cancelOfferEligible,
  grantCompletedSetup,
  healSettledDebit,
  honourLateOfferApproval,
  noteRevokeRetry,
  parkSubscription,
  releaseClaim,
} from "../src/lib/subscription-state.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const LEGACY_199 = "DKS_S_550E8400_MFX1K2A0";
const HSR_99 = "DKS_HS_550E8400_MG2B7Q10";
const HSR_R = "DKS_HR_550E8400_MG9C1D00_7F3A";

interface Stmt {
  text: string;
  values: unknown[];
}
type Answer = unknown[] | Error | undefined;

function routedSql(route: (text: string, values: unknown[]) => Answer = () => undefined) {
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

type Sql = Parameters<typeof releaseClaim>[0];
type Where = Parameters<typeof releaseClaim>[1];
const asSql = (db: ReturnType<typeof routedSql>) => db.sql as unknown as Sql;
const where = (db: ReturnType<typeof routedSql>, column: string, value: string) =>
  (column === "id" ? db.sql`s.id = ${value}` : db.sql`s.user_id = ${value}`) as unknown as Where;

interface PpCall {
  merchant: "legacy" | "hsr" | "none";
  path: string;
  body: Record<string, unknown> | null;
}
interface PpScript {
  mandate?: (id: string) => string | Response | undefined;
}

let pp: { calls: PpCall[]; posthog: Record<string, unknown>[] } = { calls: [], posthog: [] };

function fakePhonePe(script: PpScript = {}) {
  const calls: PpCall[] = [];
  const posthog: Record<string, unknown>[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const url = new URL(input);
      const raw = typeof init.body === "string" ? init.body : "";
      const body = raw.startsWith("{") ? (JSON.parse(raw) as Record<string, unknown>) : null;
      if (url.hostname.includes("posthog")) {
        if (body) posthog.push(body);
        return new Response("ok");
      }
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
      calls.push({ merchant, path, body });
      const mandateAt = /^\/subscriptions\/v2\/([^/]+)\/status$/.exec(path);
      if (mandateAt) {
        const a = script.mandate?.(mandateAt[1]) ?? "ACTIVE";
        return a instanceof Response ? a : Response.json({ merchantSubscriptionId: mandateAt[1], state: a });
      }
      return new Response("unexpected", { status: 500 });
    }),
  );
  pp = { calls, posthog };
  return pp;
}

function expectOneMerchantPerCall(calls: PpCall[]) {
  for (const call of calls) {
    const ids = `${call.path} ${JSON.stringify(call.body ?? {})}`.match(/DKS_[A-Za-z0-9_-]+/g) ?? [];
    expect(ids.length, call.path).toBeGreaterThan(0);
    for (const id of ids) expect(call.merchant, `${call.path} named ${id}`).toBe(merchantOf(id));
  }
}

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
    POSTHOG_API_KEY: "phc_test",
    ...overrides,
  });
}

const props = (event: Record<string, unknown> | undefined) =>
  (event?.properties ?? {}) as Record<string, unknown>;

afterEach(() => {
  expectOneMerchantPerCall(pp.calls);
  pp = { calls: [], posthog: [] };
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

const ELIGIBILITY_CLAUSES = [
  "s.status IN ('trialing', 'active')",
  "s.current_period_end > now()",
  "s.merchant_subscription_id IS NOT NULL",
  "s.next_debit_at > now() + interval '1 hour'",
  "s.superseded_mandate_id IS NULL",
  "s.price_paise = ?",
  "u.cancel_offer_at IS NULL",
];

describe("cancelOfferEligible — decision 5 in one fragment", () => {
  it("carries every clause over the aliases s and u, binding only the standard price", () => {
    const db = routedSql();
    const frag = cancelOfferEligible(asSql(db)) as unknown as Stmt;
    for (const clause of ELIGIBILITY_CLAUSES) expect(frag.text).toContain(clause);
    expect(frag.values).toEqual([STANDARD_PRICE_PAISE]);
    expect(frag.text.match(/ AND /g)?.length).toBe(ELIGIBILITY_CLAUSES.length - 1);
    expect(db.stmts).toEqual([]);
  });

  it("does not gate on notified_at — Pass A notifies a 1-day trial minutes after it starts", () => {
    const frag = cancelOfferEligible(asSql(routedSql())) as unknown as Stmt;
    expect(frag.text).not.toContain("notified_at");
  });
});

describe("releaseClaim — every release path's ONE statement", () => {
  it("restores the parked id at its own price and moves a switch's ₹99 into offer_mandate_id", async () => {
    const released = { user_id: USER_ID, status: "active", merchant_subscription_id: LEGACY_199 };
    const db = routedSql((t) => (t.includes("AS released_mandate_id") ? [released] : undefined));
    const rows = await releaseClaim(asSql(db), where(db, "id", "row-1"));

    expect(rows).toEqual([released]);
    expect(db.stmts).toHaveLength(1);
    const { text, values } = db.stmts[0];
    expect(text).toContain(
      "WHEN s.superseded_mandate_id IS NOT NULL THEN CASE WHEN s.trial_end IS NOT NULL AND " +
        "s.current_period_end > s.trial_end THEN 'active' ELSE 'trialing' END ELSE CASE WHEN " +
        "s.current_period_end IS NOT NULL AND s.current_period_end > now() THEN 'cancelled' ELSE 'expired' END",
    );
    expect(text).toContain(
      "merchant_subscription_id = COALESCE(s.superseded_mandate_id, s.merchant_subscription_id)",
    );
    expect(text).toContain(
      "price_paise = CASE WHEN s.superseded_mandate_id IS NOT NULL " +
        "THEN COALESCE(s.superseded_price_paise, ?) ELSE s.price_paise END",
    );
    expect(text).toContain(
      "offer_mandate_id = CASE WHEN s.offer_switch THEN s.merchant_subscription_id ELSE s.offer_mandate_id END",
    );
    expect(text).toContain("offer_switch = false");
    expect(text).toContain("superseded_mandate_id = NULL");
    expect(text).toContain("superseded_price_paise = NULL");
    expect(text).toContain("WHERE (s.id = ?) AND prior.id = s.id AND s.status = 'pending'");
    expect(text).toContain(
      "prior.merchant_subscription_id AS released_mandate_id, prior.offer_switch AS was_offer",
    );
    expect(values).toEqual([STANDARD_PRICE_PAISE, "row-1"]);
  });
});

describe("grantCompletedSetup — the offer switch runs FIRST on every grant surface", () => {
  const SWITCH = /^WITH g AS \( UPDATE subscriptions AS s SET status = CASE/;
  const GRANT = "AND s.status = 'pending' AND NOT s.offer_switch";

  it("a pending cancel_99 switches: no paid month, no debit stamps, price kept, offer spent in the same statement", async () => {
    const db = routedSql((t) =>
      SWITCH.test(t)
        ? [{ user_id: USER_ID, status: "trialing", price_paise: "9900", stale_mandate_id: LEGACY_199 }]
        : undefined,
    );
    const out = await grantCompletedSetup(asSql(db), where(db, "user", USER_ID), "OMS_1");

    expect(out).toEqual({
      kind: "switch",
      user_id: USER_ID,
      status: "trialing",
      price_paise: "9900",
      stale_mandate_id: LEGACY_199,
    });
    expect(db.stmts).toHaveLength(1);
    const { text, values } = db.stmts[0];
    expect(text).toContain(
      "SET status = CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end " +
        "THEN 'active' ELSE 'trialing' END",
    );
    expect(text).toContain("phonepe_subscription_id = COALESCE(?, s.phonepe_subscription_id)");
    expect(text).toContain("next_debit_at = GREATEST(s.next_debit_at, now() + ?::interval)");
    expect(text).toContain(
      "current_period_end = GREATEST(s.current_period_end, s.next_debit_at, now() + ?::interval)",
    );
    expect(text).toContain(
      "trial_end = CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end THEN s.trial_end " +
        "ELSE GREATEST(s.current_period_end, s.next_debit_at, now() + ?::interval) END",
    );
    for (const cleared of [
      "notified_at = NULL",
      "redemption_order_id = NULL",
      "offer_switch = false",
      "offer_mandate_id = NULL",
      "superseded_mandate_id = NULL",
      "superseded_price_paise = NULL",
    ]) {
      expect(text).toContain(cleared);
    }
    expect(text).toContain(
      "WHERE (s.user_id = ?) AND prior.id = s.id AND s.status = 'pending' AND s.offer_switch " +
        "RETURNING s.user_id, s.status, s.price_paise, prior.superseded_mandate_id AS stale_mandate_id",
    );
    expect(text).toContain(
      "stamp AS ( UPDATE users SET cancel_offer_at = COALESCE(users.cancel_offer_at, now()) " +
        "FROM g WHERE users.id = g.user_id )",
    );
    for (const untouched of [
      /paid_paise/,
      /debit_count/,
      /first_debit_at/,
      /retry_count/,
      /\bprice_paise =/,
      /\bmerchant_subscription_id =/,
    ]) {
      expect(text).not.toMatch(untouched);
    }
    expect(values).toEqual(["OMS_1", "25 hours", "25 hours", "25 hours", USER_ID]);
    expect(grantReferralReward).not.toHaveBeenCalled();
  });

  it("a plain claim falls through to the grant, which stamps paid_paise from the row's own price", async () => {
    const db = routedSql((t) =>
      t.includes(GRANT)
        ? [{ user_id: USER_ID, status: "active", price_paise: 19900, stale_mandate_id: null }]
        : undefined,
    );
    const out = await grantCompletedSetup(asSql(db), where(db, "id", "row-1"), null);

    expect(out?.kind).toBe("grant");
    expect(
      db.stmts.map((s) => (SWITCH.test(s.text) ? "switch" : s.text.includes(GRANT) ? "grant" : "?")),
    ).toEqual(["switch", "grant"]);
    const grant = db.stmts[1];
    expect(grant.text).toContain(
      "paid_paise = CASE WHEN s.trial_end IS NULL THEN s.paid_paise ELSE s.paid_paise + s.price_paise END",
    );
    expect(grant.text).toContain("WHERE (s.id = ?) AND prior.id = s.id");
    expect(grant.values).not.toContain(STANDARD_PRICE_PAISE);
    expect(grant.values).not.toContain(OFFER_PRICE_PAISE);
  });

  it("nothing pending -> null after both statements (the losing surface grants nothing)", async () => {
    const db = routedSql();
    expect(await grantCompletedSetup(asSql(db), where(db, "id", "row-1"), null)).toBeNull();
    expect(db.stmts).toHaveLength(2);
  });
});

describe("honourLateOfferApproval — a late ₹99 approval", () => {
  it("switches only a trialing/active row still on its ₹199, unparked, live and not due within the hour", async () => {
    const db = routedSql((t) =>
      t.startsWith("WITH g AS ( UPDATE subscriptions AS s SET merchant_subscription_id = s.offer_mandate_id")
        ? [{ user_id: USER_ID, status: "active", price_paise: 9900, stale_mandate_id: LEGACY_199 }]
        : undefined,
    );
    const out = await honourLateOfferApproval(asSql(db), HSR_99, "OMS_9");

    expect(out).toMatchObject({ kind: "switch", stale_mandate_id: LEGACY_199 });
    expect(db.stmts).toHaveLength(1);
    const { text, values } = db.stmts[0];
    expect(text).toContain(
      "SET merchant_subscription_id = s.offer_mandate_id, phonepe_subscription_id = ?::text, price_paise = ?",
    );
    expect(text).toContain(
      "WHERE s.offer_mandate_id = ? AND prior.id = s.id AND s.status IN ('trialing', 'active') " +
        "AND s.price_paise = ? AND s.superseded_mandate_id IS NULL AND s.current_period_end > now() " +
        "AND s.next_debit_at > now() + interval '1 hour'",
    );
    for (const cleared of ["notified_at = NULL", "redemption_order_id = NULL", "offer_mandate_id = NULL"]) {
      expect(text).toContain(cleared);
    }
    expect(text).toContain("prior.merchant_subscription_id AS stale_mandate_id");
    expect(text).toContain(
      "UPDATE users SET cancel_offer_at = COALESCE(users.cancel_offer_at, now()) FROM g",
    );
    expect(values).toEqual([
      "OMS_9",
      OFFER_PRICE_PAISE,
      "25 hours",
      "25 hours",
      "25 hours",
      HSR_99,
      STANDARD_PRICE_PAISE,
    ]);
  });

  it("returns null when no row qualifies -> the caller revokes the ₹99", async () => {
    const db = routedSql();
    expect(await honourLateOfferApproval(asSql(db), HSR_99, null)).toBeNull();
  });
});

describe("parkSubscription — the ONE park (cron, status route, pause webhook, legacy reconcile)", () => {
  it("paused: leaves the rotation from trialing/active only, and reports no cancel", async () => {
    fakePhonePe();
    const db = routedSql((t) =>
      t.startsWith("UPDATE subscriptions AS s SET status = ?")
        ? [{ user_id: USER_ID, merchant_subscription_id: HSR_99, price_paise: 9900, prior_status: "active" }]
        : undefined,
    );
    await parkSubscription(
      dualEnv(),
      asSql(db),
      db.sql`s.merchant_subscription_id = ${HSR_99}` as never,
      "paused",
    );

    const { text, values } = db.stmts[0];
    expect(text).toContain(
      "SET status = ?, next_debit_at = NULL, notified_at = NULL, updated_at = now() FROM subscriptions AS prior " +
        "WHERE (s.merchant_subscription_id = ?) AND prior.id = s.id AND (s.status IN ('trialing', 'active')) RETURNING",
    );
    expect(values).toEqual(["paused", HSR_99]);
    expect(pp.posthog).toEqual([]);
  });

  it.each([
    [9900, { price_paise: 9900, value: 99, offer: CANCEL_OFFER }],
    [19900, { price_paise: 19900, value: 199 }],
  ])(
    "cancelled: a paused row parks too, and subscription_cancel carries the row's price %s",
    async (price, want) => {
      fakePhonePe();
      const db = routedSql((t) =>
        t.startsWith("UPDATE subscriptions AS s SET status = ?")
          ? [
              {
                user_id: USER_ID,
                merchant_subscription_id: HSR_99,
                price_paise: String(price),
                prior_status: "trialing",
              },
            ]
          : undefined,
      );
      await parkSubscription(
        dualEnv(),
        asSql(db),
        where(db, "id", "row-1"),
        "cancelled",
        "revoked_at_phonepe",
      );

      expect(db.stmts[0].text).toContain("(s.status IN ('trialing', 'active', 'paused'))");
      expect(pp.posthog).toHaveLength(1);
      expect(pp.posthog[0].event).toBe("subscription_cancel");
      const p = props(pp.posthog[0]);
      expect(p).toMatchObject({
        ...want,
        reason: "revoked_at_phonepe",
        prior_status: "trialing",
        phonepe_merchant: "hsr",
      });
      if (price === STANDARD_PRICE_PAISE) expect(p).not.toHaveProperty("offer");
    },
  );

  it("cancelled with no row matched reports nothing", async () => {
    fakePhonePe();
    const db = routedSql();
    expect(await parkSubscription(dualEnv(), asSql(db), where(db, "id", "row-1"), "cancelled")).toEqual([]);
    expect(pp.posthog).toEqual([]);
  });
});

describe("healSettledDebit — a COMPLETED order on a row that never converted", () => {
  const CANDIDATE = /^SELECT COALESCE\(s\.superseded_mandate_id, s\.merchant_subscription_id\) AS mandate_id/;
  const HEAL = /^UPDATE subscriptions AS s SET status = \?, merchant_subscription_id = COALESCE/;

  function healDb(mandateId: string | null, healed: Record<string, unknown> | null) {
    return routedSql((t) => {
      if (CANDIDATE.test(t)) return mandateId === null ? [] : [{ mandate_id: mandateId }];
      if (HEAL.test(t)) return healed ? [healed] : [];
      return undefined;
    });
  }

  it("the never-converted gate holds -> nothing read at PhonePe, nothing written", async () => {
    fakePhonePe();
    const db = healDb(null, null);
    expect(await healSettledDebit(dualEnv(), asSql(db), where(db, "id", "row-1"), HSR_R)).toBeNull();
    expect(db.stmts).toHaveLength(1);
    expect(db.stmts[0].text).toContain(
      "WHERE (s.id = ?) AND s.redemption_order_id = ? AND s.trial_end IS NOT NULL " +
        "AND (s.current_period_end IS NULL OR s.current_period_end <= s.trial_end)",
    );
    expect(pp.calls).toEqual([]);
  });

  it("grants the month at the DEBITED mandate's price, and reports it at that price", async () => {
    const { calls, posthog } = fakePhonePe();
    const db = healDb(HSR_99, {
      user_id: USER_ID,
      status: "active",
      merchant_subscription_id: HSR_99,
      price_paise: "9900",
      prior_mandate_id: HSR_99,
      updated_at: new Date(),
    });
    const healed = await healSettledDebit(dualEnv(), asSql(db), where(db, "id", "row-1"), HSR_R);

    expect(healed?.status).toBe("active");
    expect(calls.map((c) => [c.merchant, c.path])).toEqual([["hsr", `/subscriptions/v2/${HSR_99}/status`]]);
    const heal = db.ran(HEAL)[0];
    expect(heal.values[0]).toBe("active");
    expect(heal.text).toContain(
      "price_paise = CASE WHEN s.superseded_mandate_id IS NOT NULL " +
        "THEN COALESCE(s.superseded_price_paise, ?) ELSE s.price_paise END",
    );
    expect(heal.text).toContain(
      "paid_paise = s.paid_paise + CASE WHEN s.superseded_mandate_id IS NOT NULL " +
        "THEN COALESCE(s.superseded_price_paise, ?) ELSE s.price_paise END",
    );
    expect(heal.text).toContain(
      "offer_mandate_id = CASE WHEN s.offer_switch THEN s.merchant_subscription_id ELSE s.offer_mandate_id END",
    );
    expect(heal.text).toContain("redemption_order_id = NULL");
    expect(heal.text).not.toContain("19900");
    expect(grantReferralReward).toHaveBeenCalledTimes(1);
    expect(posthog).toHaveLength(1);
    expect(props(posthog[0])).toMatchObject({
      order_id: HSR_R,
      value: 99,
      price_paise: 9900,
      offer: CANCEL_OFFER,
    });
  });

  it("a mandate already revoked keeps the month as 'cancelled' with no next debit", async () => {
    fakePhonePe({ mandate: () => "REVOKED" });
    const db = healDb(LEGACY_199, { user_id: USER_ID, status: "cancelled", price_paise: 19900 });
    await healSettledDebit(dualEnv(), asSql(db), where(db, "id", "row-1"), "DKS_R_550E8400_MG9C1D00_7F3A");
    const heal = db.ran(HEAL)[0];
    expect(heal.values[0]).toBe("cancelled");
    expect(heal.text).toContain("next_debit_at = ?");
    expect(heal.values).toContain(null);
  });

  it("a failed mandate read grants as 'active' (Pass A parks a dead mandate at its next notify)", async () => {
    fakePhonePe({ mandate: () => new Response("down", { status: 503 }) });
    const db = healDb(LEGACY_199, { user_id: USER_ID, status: "active", price_paise: 19900 });
    await healSettledDebit(dualEnv(), asSql(db), where(db, "id", "row-1"), "DKS_R_550E8400_MG9C1D00_7F3A");
    expect(db.ran(HEAL)[0].values[0]).toBe("active");
  });
});

describe("noteRevokeRetry and the 7d rearm", () => {
  it("parks a ₹199 the switch could not revoke in revoke_retry_mandate_id", async () => {
    const db = routedSql();
    await noteRevokeRetry(asSql(db), USER_ID, LEGACY_199);
    expect(db.stmts[0].text).toContain("SET revoke_retry_mandate_id = ?");
    expect(db.stmts[0].values).toEqual([LEGACY_199, USER_ID]);
  });

  it("7d: an unpause rearms to 'active' only for a converted row, never by comparing trial_end to now()", async () => {
    const db = routedSql();
    await rearmUnpausedSubscription(db.sql as never, { merchantSubscriptionId: HSR_99 });
    const { text, values } = db.stmts[0];
    expect(text).toContain(
      "SET status = CASE WHEN trial_end IS NOT NULL AND current_period_end > trial_end THEN 'active' ELSE 'trialing' END",
    );
    expect(text).toContain("next_debit_at = COALESCE(next_debit_at, current_period_end)");
    expect(text).toContain("AND status = 'paused'");
    expect(text).not.toContain("trial_end > now()");
    expect(values).toEqual([null, HSR_99]);
  });
});

describe("pricing, ids and analytics", () => {
  it("one offer, one price", () => {
    expect([STANDARD_PRICE_PAISE, OFFER_PRICE_PAISE, CANCEL_OFFER]).toEqual([19900, 9900, "cancel_99"]);
    expect(offerOfPrice(9900)).toBe(CANCEL_OFFER);
    expect(offerOfPrice("9900" as unknown as number)).toBe(CANCEL_OFFER);
    expect(offerOfPrice(19900)).toBeNull();
    expect(offerOfPrice(null)).toBeNull();
    expect(offerOfPrice(undefined)).toBeNull();
  });

  it("mandateCreatedAt reads a mandate id's own mint time for both merchants, and nothing else", () => {
    const before = Date.now();
    for (const merchant of ["legacy", "hsr"] as const) {
      const minted = mandateCreatedAt(buildMerchantSubscriptionId(USER_ID, merchant));
      expect(minted?.getTime()).toBeGreaterThanOrEqual(before);
      expect(minted?.getTime()).toBeLessThanOrEqual(Date.now());
      expect(mandateCreatedAt(buildMerchantOrderId(USER_ID, "S", merchant))).toBeNull();
    }
    expect(mandateCreatedAt(HSR_R)).toBeNull();
    expect(mandateCreatedAt("PKZ_S_550E8400_MG2B7Q10")).toBeNull();
    expect(mandateCreatedAt(HSR_99)?.getTime()).toBe(Number.parseInt("MG2B7Q10", 36));
  });

  it.each([
    [9900, { value: 99, price_paise: 9900, offer: CANCEL_OFFER }],
    [19900, { value: 199, price_paise: 19900 }],
  ])("subscription_active at %s paise carries the value and offer of that price", async (amount, want) => {
    const { posthog } = fakePhonePe();
    await reportPostHogFirstConversion(dualEnv(), {
      userId: USER_ID,
      transactionId: `txn-${amount}`,
      amountPaise: amount,
      merchantSubId: HSR_99,
    });
    expect(props(posthog[0])).toMatchObject(want);
    if (amount === STANDARD_PRICE_PAISE) expect(props(posthog[0])).not.toHaveProperty("offer");
  });

  it("subscription_cancel without a known price sends no price keys at all", async () => {
    const { posthog } = fakePhonePe();
    await reportPostHogSubscriptionCancel(dualEnv(), {
      userId: USER_ID,
      merchantSubId: LEGACY_199,
      reason: "user_cancel",
      priorStatus: "active",
      pricePaise: null,
    });
    const p = props(posthog[0]);
    for (const key of ["price_paise", "value", "offer"]) expect(p).not.toHaveProperty(key);
  });
});
