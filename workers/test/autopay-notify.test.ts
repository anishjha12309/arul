/**
 * cron/autopay-notify.ts — Pass B, the half that takes money. Everything is mocked: no network, no DB, no money.
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
  getAccessToken: vi.fn(async () => "token"),
  buildMerchantOrderId: vi.fn(() => "DKS_R_NEW"),
}));

/** Mirrors the real PhonePeApiError's isPermanent split -> 4xx is final, 429 is not -> that split drives every branch. */
const { FakePhonePeApiError } = vi.hoisted(() => ({
  FakePhonePeApiError: class extends Error {
    constructor(
      message: string,
      readonly status: number,
      readonly body: string,
    ) {
      super(message);
      this.name = "PhonePeApiError";
    }
    get isPermanent(): boolean {
      return this.status >= 400 && this.status < 500 && this.status !== 429;
    }
  },
}));

vi.mock("../src/lib/phonepe.js", async (importOriginal) => ({
  ...phonepe,
  merchantOf: (await importOriginal<typeof import("../src/lib/phonepe.js")>()).merchantOf,
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
function makeSql(
  passBRows: unknown[],
  passDRows: unknown[] = [],
  passARows: unknown[] = [],
  opts: { settledElsewhere?: boolean } = {},
) {
  const executed: Executed[] = [];

  const fn = vi.fn((strings: TemplateStringsArray, ...values: unknown[]) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    executed.push({ text, values });

    if (/^SELECT 1/i.test(text)) return Promise.resolve([]);
    // refreshIdleMarker — it counts paused rows too, so it must be matched BEFORE the Pass D shape
    if (text.includes("min(next_debit_at)")) {
      return Promise.resolve([{ soonest: null, in_flight: 0, paused_rechecks: passDRows.length }]);
    }
    // Pass A — notify candidates
    if (text.includes("notified_at IS NULL")) return Promise.resolve(passARows);
    // Pass B — execute candidates
    if (text.includes("notified_at IS NOT NULL")) return Promise.resolve(passBRows);
    // Pass D — parked pauses to recheck
    if (text.includes("FROM subscriptions WHERE status = 'paused'")) {
      return Promise.resolve(passDRows);
    }
    // The settle claims the order -> a row back means this run settled it, none means the webhook did
    if (text.includes("status = 'active'")) {
      return Promise.resolve(opts.settledElsewhere ? [] : [{ updated_at: new Date().toISOString() }]);
    }
    return Promise.resolve([]);
  });

  const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  return { sql, executed };
}

/** Every UPDATE the run issued -> the row's final state is asserted from these, not from a return value. */
function updates(executed: Executed[]): Executed[] {
  return executed.filter((e) => /^UPDATE subscriptions/i.test(e.text));
}

/** UPDATEs that change the row — the queue rotation only moves updated_at. */
function stateWrites(executed: Executed[]): Executed[] {
  return updates(executed).filter((e) => !e.text.startsWith("UPDATE subscriptions SET updated_at = now()"));
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

/** A row the cron parked `paused` — invisible to Pass A and Pass B, so only Pass D can ever free it. */
function pausedRow(id = "paused-1", merchantSubId = "DKS_S_PAUSED") {
  return { id, merchant_subscription_id: merchantSubId };
}

/** 05:00:20 UTC is a top-of-hour tick (Pass D runs); 05:30 is not. */
function atTick(minutesPastHour: 0 | 30): void {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(`2026-08-25T05:${minutesPastHour === 0 ? "00:20" : "30:00"}Z`));
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
    // The debit-tracking columns the CMS reads move on the SAME statement -> a settle can never activate without stamping
    // COALESCE is what keeps first_debit_at at the FIRST settle when this row renews next month
    expect(activated!.text).toContain("first_debit_at = COALESCE(first_debit_at, now())");
    expect(activated!.text).toContain("debit_count = debit_count + 1");
    // The row's own price -> a ₹99 switch books 9900 per month, never a literal ₹199
    expect(activated!.text).toContain("paid_paise = paid_paise + price_paise");
    expect(referral.grantReferralReward).toHaveBeenCalledTimes(1);
    // 'trialing' at settle is the FIRST trial->paid conversion -> PostHog ONLY
    // GA4 `purchase` and Meta `Subscribe` are gone from this path -> one conversion, one data source
    expect(posthog.reportPostHogFirstConversion).toHaveBeenCalledTimes(1);
  });

  it("counts nothing twice when the webhook settled the order first", async () => {
    // The webhook clears redemption_order_id -> the cron's claim matches no row -> no second ₹199, reward or report
    const { sql, executed } = makeSql([dueRow(10 * 60 * 1000)], [], [], { settledElsewhere: true });
    db.getDb.mockReturnValue(sql);

    phonepe.executeRedemption.mockResolvedValue({ state: "COMPLETED", transactionId: "T9" });

    await runAutopayNotify(makeEnv());

    const settle = updates(executed).find((u) => u.text.includes("status = 'active'"));
    expect(settle!.text).toContain("AND redemption_order_id = ?");
    expect(settle!.values).toContain(ORDER);
    expect(referral.grantReferralReward).not.toHaveBeenCalled();
    expect(posthog.reportPostHogFirstConversion).not.toHaveBeenCalled();
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

    expect(stateWrites(executed)).toHaveLength(0);
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

  it("sends a still-PENDING order to the back of the queue, fresh debits first", async () => {
    // Oldest-due-first with a 200 cap re-picked the same in-flight orders every run -> no newer debit was redeemed
    const { sql, executed } = makeSql([dueRow(3 * HOUR)]);
    db.getDb.mockReturnValue(sql);

    phonepe.getOrderStatus.mockResolvedValue({
      state: "PENDING",
      expireAt: Date.now() + 24 * HOUR,
    });

    await runAutopayNotify(makeEnv());

    const select = executed.find((e) => e.text.includes("notified_at IS NOT NULL"));
    expect(select!.text).toContain("ORDER BY (next_debit_at < ?) ASC, updated_at ASC");
    const touch = updates(executed).find((u) => u.text.includes("SET updated_at = now()"));
    expect(touch, "a PENDING check must rotate the row").toBeDefined();
    expect(touch!.text).toContain("AND redemption_order_id = ?");
    expect(touch!.values).toEqual(["row-1", ORDER]);
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

  it("bounds the Pass B query itself off the top of the hour — a stale row never takes a slot", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-08-25T05:30:00Z"));
    try {
      const { sql, executed } = makeSql([]);
      db.getDb.mockReturnValue(sql);

      await runAutopayNotify(makeEnv());

      const passB = executed.find((e) => e.text.includes("notified_at IS NOT NULL"));
      expect(passB).toBeDefined();
      expect(passB!.values).toContain(new Date(Date.now() - 48 * HOUR).toISOString());
    } finally {
      vi.useRealTimers();
    }
  });

  it("drops that bound on the top-of-hour tick — stale rows are in scope exactly when the loop acts", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-08-25T05:00:20Z"));
    try {
      const { sql, executed } = makeSql([]);
      db.getDb.mockReturnValue(sql);

      await runAutopayNotify(makeEnv());

      const passB = executed.find((e) => e.text.includes("notified_at IS NOT NULL"));
      expect(passB).toBeDefined();
      // Epoch, not the 48h floor -> the same statement, no stale row excluded
      expect(passB!.values).toContain(new Date(0).toISOString());
      expect(passB!.values).not.toContain(new Date(Date.now() - 48 * HOUR).toISOString());
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
    expect(stateWrites(executed)).toHaveLength(0);
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

describe("Pass D — a paused mandate the webhook never told us about", () => {
  it("rearms a paused row whose mandate is ACTIVE again at PhonePe", async () => {
    atTick(0);
    try {
      const { sql, executed } = makeSql([], [pausedRow()]);
      db.getDb.mockReturnValue(sql);
      phonepe.getSubscriptionStatus.mockResolvedValue({ state: "ACTIVE" });

      await runAutopayNotify(makeEnv());

      expect(phonepe.getSubscriptionStatus).toHaveBeenCalledWith(expect.anything(), "DKS_S_PAUSED");
      const rearm = updates(executed).find((u) =>
        u.text.includes("COALESCE(next_debit_at, current_period_end)"),
      );
      expect(rearm, "an ACTIVE mandate must put the row back in the rotation").toBeDefined();
      // Status AND clock, on one statement -> restoring only the status is the zombie-row bug
      // Converted = the period ran past the trial -> an unpaused never-converted trial stays 'trialing'
      expect(rearm!.text).toContain("current_period_end > trial_end THEN 'active' ELSE 'trialing'");
      // The guard the webhook carries -> a restore must never resurrect a cancelled or expired row
      expect(rearm!.text).toContain("AND status = 'paused'");
      expect(rearm!.values).toContain("paused-1");
    } finally {
      vi.useRealTimers();
    }
  });

  it("leaves a row still PAUSED at PhonePe exactly as it was", async () => {
    atTick(0);
    try {
      const { sql, executed } = makeSql([], [pausedRow()]);
      db.getDb.mockReturnValue(sql);
      phonepe.getSubscriptionStatus.mockResolvedValue({ state: "PAUSED" });

      await runAutopayNotify(makeEnv());

      // The ONLY write is the rotation cursor -> nothing about the subscription itself moves
      expect(updates(executed)).toHaveLength(1);
      expect(updates(executed)[0].text).toBe(
        "UPDATE subscriptions SET updated_at = now() WHERE id = ? AND status = 'paused'",
      );
      expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("parks a REVOKED mandate as cancelled instead of re-asking forever", async () => {
    atTick(0);
    try {
      const { sql, executed } = makeSql([], [pausedRow()]);
      db.getDb.mockReturnValue(sql);
      phonepe.getSubscriptionStatus.mockResolvedValue({ state: "REVOKED" });

      await runAutopayNotify(makeEnv());

      const parked = updates(executed).find((u) => u.text.includes("status = ?"));
      expect(parked, "a revoked mandate must be parked, not left paused").toBeDefined();
      expect(parked!.values[0]).toBe("cancelled");
      // Parking is a BILLING decision -> current_period_end is untouched -> access runs out on its own
      expect(parked!.text).toContain("next_debit_at = NULL");
      expect(parked!.text).not.toContain("current_period_end");
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not run at all off the top of the hour", async () => {
    atTick(30);
    try {
      const { sql, executed } = makeSql([], [pausedRow()]);
      db.getDb.mockReturnValue(sql);
      phonepe.getSubscriptionStatus.mockResolvedValue({ state: "ACTIVE" });

      await runAutopayNotify(makeEnv());

      // Not even the SELECT -> a pause can wait 45 min; a debit due this tick cannot
      expect(executed.some((e) => e.text.includes("FROM subscriptions WHERE status = 'paused'"))).toBe(false);
      expect(phonepe.getSubscriptionStatus).not.toHaveBeenCalled();
      expect(updates(executed)).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("charges 4 rows at once and never a 5th", async () => {
    const passB = Array.from({ length: 10 }, (_, i) => ({ ...dueRow(10 * 60 * 1000), id: `row-${i}` }));
    const { sql } = makeSql(passB);
    db.getDb.mockReturnValue(sql);

    let inFlight = 0;
    let peak = 0;
    phonepe.executeRedemption.mockImplementation(async () => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight -= 1;
      return { state: "PENDING", transactionId: "T" };
    });

    await runAutopayNotify(makeEnv());

    expect(phonepe.executeRedemption).toHaveBeenCalledTimes(10);
    expect(peak).toBe(4);
    // One token per merchant before the lanes start -> no refresh race between them
    expect(phonepe.getAccessToken).toHaveBeenCalledTimes(1);
  });

  it("never spends a call Pass B needed — the run's budget is shared", async () => {
    atTick(0);
    try {
      // A full Pass B of settling rows: 1 reconcile call + 3 reporter subrequests each -> the 2400 budget is gone
      const passB = Array.from({ length: 800 }, () => dueRow(3 * HOUR, "active"));
      const { sql, executed } = makeSql(passB, [pausedRow()]);
      db.getDb.mockReturnValue(sql);
      phonepe.getOrderStatus.mockResolvedValue({
        state: "COMPLETED",
        expireAt: Date.now() + 24 * HOUR,
      });

      await runAutopayNotify(makeEnv());

      // Debits outrank pause housekeeping: Pass D stops before its first call, and retries next hour
      expect(phonepe.getSubscriptionStatus).not.toHaveBeenCalled();
      expect(executed.some((e) => e.text.includes("FROM subscriptions WHERE status = 'paused'"))).toBe(false);
      expect(updates(executed).some((u) => u.text.includes("status = 'active'"))).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("Pass B — the 45-day dunning ladder", () => {
  const failedOrder = () =>
    phonepe.getOrderStatus.mockResolvedValue({
      state: "FAILED",
      expireAt: Date.now() + 24 * HOUR,
    });

  /** The ladder reschedule UPDATE, if the run issued one -> its absence is as load-bearing as its contents. */
  const ladderUpdate = (executed: Executed[]) =>
    updates(executed).find((u) => u.text.includes("retry_count") && u.text.includes("next_debit_at"));

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

describe("Pass A — a permanent rejection of a mandate PhonePe once confirmed alarms, never parks", () => {
  // A misroute, a PhonePe-side bug or a config slip answers 4xx for EVERY due row at once -> parking them all
  // cancelled stops billing for good. Only an unproven mandate is parked; a proven one is re-asked later
  const dueForNotify = (extra: Record<string, unknown> = {}) => ({
    id: "row-a",
    user_id: "user-a",
    merchant_subscription_id: SUB,
    next_debit_at: new Date(Date.now() + 2 * HOUR).toISOString(),
    current_period_end: new Date(Date.now() + 2 * HOUR).toISOString(),
    phonepe_subscription_id: null,
    debit_count: 0,
    ...extra,
  });
  const notFound = () =>
    new FakePhonePeApiError(
      "PhonePe subscription status error 400",
      400,
      '{"code":"SUBSCRIPTION_NOT_FOUND"}',
    );
  const parked = (executed: Executed[]) =>
    updates(executed).some((u) => u.text.includes("SET status = ?") && u.values.includes("cancelled"));
  const backedOff = (executed: Executed[]) =>
    updates(executed).find((u) => u.text.includes("SET next_debit_at = ?"));

  it.each([
    ["never debited", {}],
    // phonepe_subscription_id is on ~every row in production, so it proves nothing -> trial parks stay as they were
    ["never debited, even with PhonePe's subscription id on the row", { phonepe_subscription_id: "OMS123" }],
  ])("still parks a mandate that was %s", async (_why, extra) => {
    const { sql, executed } = makeSql([], [], [dueForNotify(extra)]);
    db.getDb.mockReturnValue(sql);
    phonepe.getSubscriptionStatus.mockRejectedValue(notFound());

    await runAutopayNotify(makeEnv());

    expect(parked(executed)).toBe(true);
  });

  it.each([
    ["the mandate has been debited once", { debit_count: 1 }],
    ["the mandate has renewed", { debit_count: 3 }],
  ])("does NOT park when %s — backs the row off and alarms", async (_why, extra) => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { sql, executed } = makeSql([], [], [dueForNotify(extra)]);
    db.getDb.mockReturnValue(sql);
    phonepe.getSubscriptionStatus.mockRejectedValue(notFound());

    await runAutopayNotify(makeEnv());

    expect(parked(executed)).toBe(false);
    expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
    const backoff = backedOff(executed);
    expect(backoff, "the row must leave Pass A's window, or it takes a slot every tick").toBeDefined();
    // Pass A selects next_debit_at <= now + 24h -> the new value must sit past that window
    expect(new Date(backoff!.values[0] as string).getTime()).toBeGreaterThan(Date.now() + 24 * HOUR);
    expect(backoff!.text).toContain("status IN ('trialing', 'active')");
    expect(errors.mock.calls.some((c) => String(c[0]).includes("ALARM"))).toBe(true);
    errors.mockRestore();
  });

  it("does NOT park a proven mandate whose notify is rejected right after an ACTIVE status read", async () => {
    const { sql, executed } = makeSql([], [], [dueForNotify({ debit_count: 1 })]);
    db.getDb.mockReturnValue(sql);
    phonepe.getSubscriptionStatus.mockResolvedValue({ state: "ACTIVE" });
    phonepe.notifyRedemption.mockRejectedValue(
      new FakePhonePeApiError("PhonePe notify error 400", 400, "{}"),
    );

    await runAutopayNotify(makeEnv());

    expect(parked(executed)).toBe(false);
    expect(backedOff(executed)).toBeDefined();
  });

  it("parks a proven mandate once it is past the 45-day dunning wall", async () => {
    const { sql, executed } = makeSql(
      [],
      [],
      [
        dueForNotify({
          debit_count: 2,
          current_period_end: new Date(Date.now() - 46 * 24 * HOUR).toISOString(),
        }),
      ],
    );
    db.getDb.mockReturnValue(sql);
    phonepe.getSubscriptionStatus.mockRejectedValue(notFound());

    await runAutopayNotify(makeEnv());

    expect(parked(executed)).toBe(true);
  });

  it("selects the columns the proof needs", async () => {
    const { sql, executed } = makeSql([]);
    db.getDb.mockReturnValue(sql);

    await runAutopayNotify(makeEnv());

    const passA = executed.find((e) => e.text.includes("notified_at IS NULL"));
    expect(passA?.text).toContain("debit_count");
    expect(passA?.text).toContain("current_period_end");
  });
});
