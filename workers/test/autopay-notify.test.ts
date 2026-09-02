/**
 * cron/autopay-notify.ts — Pass B, the half that takes money. Everything is mocked: no network, no DB, no money.
 *
 * This cron had no test at all, and the gap cost real money -> two subscribers were debited while their rows stayed trialing
 * They paid and were locked out for two days -> the defect was ORDERING, not logic
 * The reconcile that recovers an already-settled order sat INSIDE the try, BELOW the `redeem` call
 * So the moment `redeem` started throwing, the recovery became unreachable and the row was stranded forever
 * Two properties make that class of bug impossible, and both are asserted here
 * 1. ORDER STATUS, never the `redeem` response, is the authority on whether money moved
 *    It is consulted BEFORE re-charging and AGAIN on the throw path
 * 2. A row can never be left both unsettled and unchanged -> it settles, is parked, or gets a fresh order
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

const phonepe = vi.hoisted(() => ({
  executeRedemption: vi.fn(),
  getOrderStatus: vi.fn(),
  getSubscriptionStatus: vi.fn(),
  notifyRedemption: vi.fn(),
  buildMerchantOrderId: vi.fn(() => "DKS_R_NEW"),
}));

/** Mirrors the real PhonePeApiError's isPermanent split -> 4xx is final, 429 is not -> that split drives every branch. */
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



const posthog = vi.hoisted(() => ({
  reportPostHogFirstConversion: vi.fn(),
  reportPostHogSubscriptionCancel: vi.fn(),
}));
vi.mock("../src/lib/posthog.js", () => posthog);

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
 * A SQL mock that dispatches on the query TEXT -> this cron runs several different statements per pass.
 * A one-size mock cannot express "Pass A finds nothing, Pass B finds this row"
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

/** Every UPDATE the run issued -> the row's final state is asserted from these, not from a return value. */
function updates(executed: Executed[]): Executed[] {
  return executed.filter((e) => /^UPDATE subscriptions/i.test(e.text));
}

function dueRow(overdueMs: number, status = "trialing", notifiedAgoMs = 25 * HOUR, retryCount = 0) {
  return {
    id: "row-1",
    user_id: "user-1",
    status,
    merchant_subscription_id: SUB,
    redemption_order_id: ORDER,
    retry_count: retryCount,
    next_debit_at: new Date(Date.now() - overdueMs).toISOString(),
    // The settle path writes current_period_end and next_debit_at as the SAME instant
    // The failure path never moves current_period_end -> it is the dunning ladder's anchor
    current_period_end: new Date(Date.now() - overdueMs).toISOString(),
    // Notified 25h ago by default -> past PhonePe's 24h notify->execute window -> inside it, execute is skipped
    notified_at: new Date(Date.now() - notifiedAgoMs).toISOString(),
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
    // The exact production sequence -> an earlier run redeemed, the debit settled seconds later, every run since throws
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
    expect(referral.grantReferralReward).toHaveBeenCalledTimes(1);
    // 'trialing' at settle is the FIRST trial->paid conversion -> PostHog ONLY
    // GA4 `purchase` and Meta `Subscribe` are gone from this path -> one conversion, one data source
    expect(posthog.reportPostHogFirstConversion).toHaveBeenCalledTimes(1);
  });

  it("reports a RENEWAL (prior status 'active') to nothing — never PostHog", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR, "active")]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "COMPLETED",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    expect(updates(executed).some((u) => u.text.includes("status = 'active'"))).toBe(true);
    expect(posthog.reportPostHogFirstConversion).not.toHaveBeenCalled();
  });

  it("asks order status BEFORE re-charging an overdue row", async () => {
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "COMPLETED",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    // Already settled -> charging again is a SECOND debit attempt against a customer who already paid
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
    expect(posthog.reportPostHogFirstConversion).not.toHaveBeenCalled();
  });
});

describe("Pass B — PhonePe's 24h notify→execute window", () => {
  it("makes NO PhonePe call for a row re-notified less than 24h ago (recycled order)", async () => {
    // The production starvation loop -> Pass A re-notifies a recycled order and the SAME run executes it
    // That answers 400 SUBSCRIPTION_DEBIT_EXECUTE_INTERVAL_NOT_STARTED -> three wasted subrequests per row per tick
    // The fresh rows behind it were never reached -> conversions stopped while the cron looked healthy
    const { sql, executed } = makeSql([dueRow(30 * HOUR, "trialing", 2 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    await runAutopayNotify(makeEnv());

    expect(phonepe.getOrderStatus).not.toHaveBeenCalled();
    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
    expect(updates(executed)).toHaveLength(0);
  });
});

describe("Pass B — no pointless redeem against a PhonePe-controlled retry", () => {
  it("does not re-redeem an order already PENDING", async () => {
    // PhonePe answers 400 DUPLICATE_TXN_REQUEST here -> that error line every tick is what turns the log into noise
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "PENDING",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
  });

  it("makes NO call for an order older than 48h off the top of the hour", async () => {
    // A pile of stale PENDING orders once ate most of the call budget on EVERY tick
    // Past PhonePe's retry window they poll on the hour only -> fresh executes get the budget back
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-08-25T05:30:00Z"));
    try {
      const { sql } = makeSql([dueRow(60 * HOUR, "trialing", 60 * HOUR)]);
      db.getDb.mockReturnValue(sql);

      await runAutopayNotify(makeEnv());

      expect(phonepe.getOrderStatus).not.toHaveBeenCalled();
      expect(phonepe.executeRedemption).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("still reconciles an order older than 48h on the top-of-hour tick", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-08-25T05:00:20Z"));
    try {
      const { sql } = makeSql([dueRow(60 * HOUR, "trialing", 60 * HOUR)]);
      db.getDb.mockReturnValue(sql);
      phonepe.getOrderStatus.mockResolvedValue({
        state: "PENDING",
        expireAt: Date.now() + 12 * HOUR,
      });

      await runAutopayNotify(makeEnv());

      expect(phonepe.getOrderStatus).toHaveBeenCalledTimes(1);
      expect(phonepe.executeRedemption).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps executing a RECYCLED row every tick — its fresh order resets notified_at", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-08-25T05:30:00Z"));
    try {
      // The debit is 60h overdue, but Pass A minted a NEW order 25h ago -> age is measured from notified_at
      const { sql } = makeSql([dueRow(60 * HOUR, "trialing", 25 * HOUR)]);
      db.getDb.mockReturnValue(sql);
      phonepe.getOrderStatus.mockResolvedValue({
        state: "NOTIFIED",
        expireAt: Date.now() + 24 * HOUR,
      });
      phonepe.executeRedemption.mockResolvedValue({ state: "PENDING", transactionId: "T1" });

      await runAutopayNotify(makeEnv());

      expect(phonepe.executeRedemption).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
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
    // A failed read tells us NOTHING -> treating it as "in flight" stops charging a subscriber on every gateway blip
    const { sql } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockRejectedValue(new Error("gateway timeout"));
    phonepe.executeRedemption.mockResolvedValue({ state: "COMPLETED", transactionId: "T4" });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).toHaveBeenCalledOnce();
  });

  it("does not burn a mandate-status call on a duplicate", async () => {
    // Freshly due -> no reconcile-first runs -> the duplicate surfaces as a THROW, which is the path under test
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

    // A duplicate PROVES the mandate works -> asking after its state burns a call to learn nothing
    expect(phonepe.getSubscriptionStatus).not.toHaveBeenCalled();
    // And it must never be mistaken for a dead subscription -> parking a working mandate stops all future billing
    expect(updates(executed)).toHaveLength(0);
  });
});

describe("Pass B — a row is never stranded", () => {
  it("parks a revoked mandate instead of retrying it hourly forever", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    // The order was announced but never executed -> the user killed the mandate before it could run
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
    // The debit is still OWED -> next_debit_at must not move -> but this dead order can never carry it
    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
  });

  it("does NOT recycle when the status read itself failed", async () => {
    // A network blip must never be mistaken for a dead order -> recycling on a failed read mints a SECOND order
    // That debits the user twice -> `dead` is only ever true off a successful read
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

describe("Pass B — the 45-day dunning ladder", () => {
  // The business rule: a failed renewal debit is pursued for 45 days on a SPACED ladder, not daily until five failures
  // Each rung is a FRESH notify plus order -> PhonePe's 1-attempt+3-retries/48h cap applies INSIDE one order
  // Each retry lands at 21:30 UTC, which is 03:00 IST -> inside NPCI's non-peak autopay execution window

  const failedOrder = () =>
    phonepe.getOrderStatus.mockResolvedValue({
      state: "FAILED",
      expireAt: Date.now() + 24 * HOUR,
    });

  /** The ladder reschedule UPDATE, if the run issued one -> its absence is as load-bearing as its contents. */
  const ladderUpdate = (executed: Executed[]) =>
    updates(executed).find(
      (u) => u.text.includes("retry_count") && u.text.includes("next_debit_at"),
    );

  it("schedules the first retry ~2 days out at 21:30 UTC — not tomorrow", async () => {
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);
    failedOrder();

    await runAutopayNotify(makeEnv());

    const u = ladderUpdate(executed);
    expect(u, "a FAILED debit must reschedule itself up the ladder").toBeDefined();
    expect(u?.values[0]).toBe(1); // retry_count
    const next = new Date(u?.values[1] as string);
    // The anchor plus the first rung, aligned FORWARD to the next 21:30 UTC -> assert a range, since alignment adds up to 24h
    expect(next.getTime()).toBeGreaterThan(Date.now() + 24 * HOUR);
    expect(next.getTime()).toBeLessThan(Date.now() + 4 * 24 * HOUR);
    expect(next.getUTCHours()).toBe(21);
    expect(next.getUTCMinutes()).toBe(30);
    // Rescheduled, never expired -> the ladder still has rungs left -> expiring here shortens the dunning window
    expect(updates(executed).some((x) => x.text.includes("'expired'"))).toBe(false);
  });

  it("still schedules the final rung at retry_count 5 (the day-45 attempt)", async () => {
    const { sql, executed } = makeSql([dueRow(32 * 24 * HOUR, "active", 25 * HOUR, 5)]);
    db.getDb.mockReturnValue(sql);
    failedOrder();

    await runAutopayNotify(makeEnv());

    const u = ladderUpdate(executed);
    expect(u).toBeDefined();
    expect(u?.values[0]).toBe(6);
    expect(updates(executed).some((x) => x.text.includes("'expired'"))).toBe(false);
  });

  it("expires the subscription when the day-45 attempt also fails", async () => {
    const { sql, executed } = makeSql([dueRow(45 * 24 * HOUR, "active", 25 * HOUR, 6)]);
    db.getDb.mockReturnValue(sql);
    failedOrder();

    await runAutopayNotify(makeEnv());

    expect(updates(executed).some((x) => x.text.includes("'expired'"))).toBe(true);
    expect(ladderUpdate(executed)?.text ?? "").not.toContain("next_debit_at");
  });

  it("expires a row whose orders die unsettled past the 45-day wall, instead of minting order ∞", async () => {
    // A mandate whose orders forever sit NOTIFIED recycles a fresh order without ever touching retry_count
    // That was unbounded before the wall existed -> the FAILED ladder never advances for it
    // Past the dunning window the dead order must EXPIRE the row, not recycle again
    const row = dueRow(46 * 24 * HOUR);
    const { sql, executed } = makeSql([row]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "NOTIFIED",
      expireAt: Date.now() - HOUR, // dead: PhonePe will never settle it
    });

    await runAutopayNotify(makeEnv());

    expect(updates(executed).some((x) => x.text.includes("'expired'"))).toBe(true);
    // The recycle shape — clear-for-re-notify with no status change — must NOT run past the wall
    expect(
      updates(executed).some(
        (x) => x.text.includes("redemption_order_id = NULL") && !x.text.includes("'expired'"),
      ),
    ).toBe(false);
    expect(phonepe.executeRedemption).not.toHaveBeenCalled();
  });
});
