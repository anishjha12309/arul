/**
 * Unit tests for cron/autopay-notify.ts — Pass B, the half that takes money.
 *
 * WHY THIS FILE EXISTS: this cron had no test at all, and the gap cost real
 * money. On 2026-08-16 and 08-17 two subscribers were debited ₹199 each at
 * PhonePe while their Neon rows stayed `trialing` — they paid and were locked
 * out for two days. The defect was ordering: the reconcile that recovers an
 * already-settled order sat INSIDE the try block, BELOW the `redeem` call, so
 * the moment `redeem` started throwing ("order already completed") the recovery
 * became unreachable and the row was stranded forever.
 *
 * Two properties make that class of bug impossible, and both are asserted here:
 *   1. Order status — not the `redeem` response — is the authority on whether
 *      money moved. It is consulted BEFORE re-charging and AGAIN on the throw
 *      path.
 *   2. A row can never be left both unsettled and unchanged forever: it either
 *      settles, gets parked (mandate gone), or gets a fresh order (dead order).
 *
 * Everything is mocked — no network, no live DB, no money.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

const phonepe = vi.hoisted(() => ({
  executeRedemption: vi.fn(),
  getOrderStatus: vi.fn(),
  getSubscriptionStatus: vi.fn(),
  notifyRedemption: vi.fn(),
  buildMerchantOrderId: vi.fn(() => "DKS_R_NEW"),
}));

/** Mirrors the real PhonePeApiError's isPermanent split (4xx final, 429 not). */
const { FakePhonePeApiError } = vi.hoisted(() => ({
  FakePhonePeApiError: class extends Error {
    constructor(message: string, readonly status: number, readonly body: string) {
      super(message);
      this.name = "PhonePeApiError";
    }
    get isPermanent(): boolean {
      return this.status >= 400 && this.status < 500 && this.status !== 429;
    }
  },
}));

vi.mock("../src/lib/phonepe.js", () => ({
  ...phonepe,
  PhonePeApiError: FakePhonePeApiError,
}));

const referral = vi.hoisted(() => ({ grantReferralReward: vi.fn() }));
vi.mock("../src/lib/referral.js", () => referral);

const ga4 = vi.hoisted(() => ({ reportServerPurchase: vi.fn() }));
vi.mock("../src/lib/ga4.js", () => ga4);

const db = vi.hoisted(() => ({ getDb: vi.fn() }));
vi.mock("../src/lib/db.js", () => ({
  getDb: db.getDb,
  toDate: (v: unknown) => (v == null ? null : new Date(v as string)),
}));

import { runAutopayNotify } from "../src/cron/autopay-notify.js";
import type { Env } from "../src/env.js";

const HOUR = 60 * 60 * 1000;
const SUB = "DKS_S_TEST";
const ORDER = "DKS_R_TEST";

interface Executed {
  text: string;
  values: unknown[];
}

/**
 * Tagged-template SQL mock that dispatches on the query text, because this cron
 * runs five different statements per pass and a one-size mock cannot express
 * "Pass A finds nothing, Pass B finds this row".
 */
function makeSql(passBRows: unknown[]) {
  const executed: Executed[] = [];

  const fn = vi.fn((strings: TemplateStringsArray, ...values: unknown[]) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    executed.push({ text, values });

    if (/^SELECT 1/i.test(text)) return Promise.resolve([]);
    // refreshIdleMarker
    if (text.includes("min(next_debit_at)")) {
      return Promise.resolve([{ soonest: null, in_flight: 0 }]);
    }
    // Pass A — notify candidates
    if (text.includes("notified_at IS NULL")) return Promise.resolve([]);
    // Pass B — execute candidates
    if (text.includes("notified_at IS NOT NULL")) return Promise.resolve(passBRows);
    return Promise.resolve([]);
  });

  const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  return { sql, executed };
}

/** Every UPDATE the run issued, for asserting what the row became. */
function updates(executed: Executed[]): Executed[] {
  return executed.filter((e) => /^UPDATE subscriptions/i.test(e.text));
}

function dueRow(overdueMs: number) {
  return {
    id: "row-1",
    user_id: "user-1",
    merchant_subscription_id: SUB,
    redemption_order_id: ORDER,
    retry_count: 0,
    next_debit_at: new Date(Date.now() - overdueMs).toISOString(),
  };
}

function makeEnv(): Env {
  const store = new Map<string, string>();
  return {
    KV: {
      get: vi.fn(async (k: string) => store.get(k) ?? null),
      put: vi.fn(async (k: string, v: string) => void store.set(k, v)),
      delete: vi.fn(async (k: string) => void store.delete(k)),
    },
    PHONEPE_ENV: "SANDBOX",
  } as unknown as Env;
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("Pass B — a settled debit is always recorded", () => {
  it("recovers the money when redeem throws because the order ALREADY settled", async () => {
    // The exact production sequence: an earlier run redeemed successfully, the
    // UPI debit settled ~30s later, and every run since throws on re-redeem.
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "COMPLETED",
      expireAt: Date.now() + 24 * HOUR,
    });
    phonepe.executeRedemption.mockRejectedValue(
      new FakePhonePeApiError("PhonePe execute error 400: already completed", 400, "{}"),
    );

    await runAutopayNotify(makeEnv());

    const activated = updates(executed).find((u) => u.text.includes("status = 'active'"));
    expect(activated, "a COMPLETED order must activate the row").toBeDefined();
    // The month the user paid for, and the GA4 purchase Google Ads never saw.
    expect(ga4.reportServerPurchase).toHaveBeenCalledTimes(1);
    expect(referral.grantReferralReward).toHaveBeenCalledTimes(1);
  });

  it("asks order status BEFORE re-charging an overdue row", async () => {
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "COMPLETED",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    // Already settled → charging again would be a second debit attempt.
    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
    expect(phonepe.getOrderStatus).toHaveBeenCalledWith(expect.anything(), ORDER);
  });

  it("still charges a freshly-due row (nothing to reconcile yet)", async () => {
    const { sql, executed } = makeSql([dueRow(10 * 60 * 1000)]); // 10 min overdue
    db.getDb.mockReturnValue(sql);

    phonepe.executeRedemption.mockResolvedValue({ state: "COMPLETED", transactionId: "T1" });

    await runAutopayNotify(makeEnv());

    expect(phonepe.getOrderStatus).not.toHaveBeenCalled();
    expect(phonepe.executeRedemption).toHaveBeenCalledOnce();
    expect(updates(executed).some((u) => u.text.includes("status = 'active'"))).toBe(true);
  });

  it("leaves a genuinely PENDING debit alone for the next run", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "PENDING",
      expireAt: Date.now() + 24 * HOUR,
    });
    phonepe.executeRedemption.mockResolvedValue({ state: "PENDING", transactionId: "T2" });

    await runAutopayNotify(makeEnv());

    expect(updates(executed)).toHaveLength(0);
    expect(ga4.reportServerPurchase).not.toHaveBeenCalled();
  });
});

describe("Pass B — no pointless redeem against a PhonePe-controlled retry", () => {
  it("does not re-redeem an order already PENDING", async () => {
    // PhonePe answers 400 DUPLICATE_TXN_REQUEST here, and that error line every
    // hour is what turns the log into noise. Skip the call instead.
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "PENDING",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
  });

  it("DOES redeem an order still at NOTIFIED — nothing has triggered it yet", async () => {
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "NOTIFIED",
      expireAt: Date.now() + 24 * HOUR,
    });
    phonepe.executeRedemption.mockResolvedValue({ state: "PENDING", transactionId: "T3" });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).toHaveBeenCalledOnce();
  });

  it("still redeems when the status read FAILED — null state is not 'skip'", async () => {
    // A failed read tells us nothing. Treating it as "in flight" would silently
    // stop charging a subscriber every time the gateway blipped.
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockRejectedValue(new Error("gateway timeout"));
    phonepe.executeRedemption.mockResolvedValue({ state: "COMPLETED", transactionId: "T4" });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).toHaveBeenCalledOnce();
  });

  it("does not burn a mandate-status call on a duplicate", async () => {
    // Freshly due, so no reconcile-first; the duplicate surfaces as a throw.
    const { sql, executed } = makeSql([dueRow(10 * 60 * 1000)]);
    db.getDb.mockReturnValue(sql);

    phonepe.executeRedemption.mockRejectedValue(
      new FakePhonePeApiError(
        "PhonePe execute error 400: " +
          '{"code":"DUPLICATE_TXN_REQUEST","message":"Another redemption request is not allowed"}',
        400,
        '{"code":"DUPLICATE_TXN_REQUEST"}',
      ),
    );
    phonepe.getOrderStatus.mockResolvedValue({
      state: "PENDING",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    // A duplicate proves the mandate works — asking after it learns nothing.
    expect(phonepe.getSubscriptionStatus).not.toHaveBeenCalled();
    // And it must never be mistaken for a dead subscription.
    expect(updates(executed)).toHaveLength(0);
  });
});

describe("Pass B — a row is never stranded", () => {
  it("parks a revoked mandate instead of retrying it hourly forever", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    // Order was announced but never executed; the user killed the mandate.
    phonepe.getOrderStatus.mockResolvedValue({
      state: "NOTIFIED",
      expireAt: Date.now() + 24 * HOUR,
    });
    phonepe.executeRedemption.mockRejectedValue(
      new FakePhonePeApiError("PhonePe execute error 400: mandate revoked", 400, "{}"),
    );
    phonepe.getSubscriptionStatus.mockResolvedValue({ state: "REVOKED" });

    await runAutopayNotify(makeEnv());

    const parked = updates(executed).find((u) => u.text.includes("status = ?"));
    expect(parked, "a revoked mandate must be parked").toBeDefined();
    expect(parked?.values[0]).toBe("cancelled");
  });

  it("recycles an order that outlived its own expireAt", async () => {
    const { sql, executed } = makeSql([dueRow(80 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "NOTIFIED",
      expireAt: Date.now() - HOUR, // dead: PhonePe will never settle it
    });

    await runAutopayNotify(makeEnv());

    const recycled = updates(executed).find((u) => u.text.includes("redemption_order_id = NULL"));
    expect(recycled, "a dead order must be cleared for re-notify").toBeDefined();
    // Debit is still owed — do not charge again on this dead order.
    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
  });

  it("does NOT recycle when the status read itself failed", async () => {
    // A network blip must never be mistaken for a dead order: recycling on a
    // failed read could mint a second order and debit the user twice.
    const { sql, executed } = makeSql([dueRow(80 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockRejectedValue(new Error("connection reset"));
    phonepe.executeRedemption.mockRejectedValue(new Error("connection reset"));

    await runAutopayNotify(makeEnv());

    expect(updates(executed).some((u) => u.text.includes("redemption_order_id = NULL"))).toBe(false);
  });

  it("does not park on a transient 5xx — that row must retry", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "NOTIFIED",
      expireAt: Date.now() + 24 * HOUR,
    });
    phonepe.executeRedemption.mockRejectedValue(
      new FakePhonePeApiError("PhonePe execute error 503", 503, "{}"),
    );

    await runAutopayNotify(makeEnv());

    expect(phonepe.getSubscriptionStatus).not.toHaveBeenCalled();
    expect(updates(executed)).toHaveLength(0);
  });

  it("never throws out of the scan when PhonePe is down", async () => {
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockRejectedValue(new Error("gateway down"));
    phonepe.executeRedemption.mockRejectedValue(new Error("gateway down"));

    await expect(runAutopayNotify(makeEnv())).resolves.toBeUndefined();
  });
});
