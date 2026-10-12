/**
 * lib/order-outcomes.ts — the outcome log rides right behind billing writes, so the one property that matters is that
 * it can never throw into them. Then: every bind is a string, number or null, and PhonePe's codes land in the columns
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const db = vi.hoisted(() => ({ getDb: vi.fn() }));
vi.mock("../src/lib/db.js", () => ({ getDb: db.getDb }));

import type { Env } from "../src/env.js";
import { pruneOrderOutcomes, recordOrderOutcome } from "../src/lib/order-outcomes.js";

interface Call {
  text: string;
  values: unknown[];
}

function capture(answer: (text: string) => unknown = () => Promise.resolve([])) {
  const calls: Call[] = [];
  const sql = Object.assign(
    vi.fn((strings: TemplateStringsArray, ...values: unknown[]) => {
      const text = strings.join("?").replace(/\s+/g, " ").trim();
      calls.push({ text, values });
      return answer(text);
    }),
    { end: vi.fn().mockResolvedValue(undefined) },
  );
  return { sql, calls };
}

// The INSERT's bind order -> named so an assertion reads as the column it checks
const COL = {
  order: 0,
  mandate: 1,
  user: 2,
  event: 3,
  state: 4,
  code: 5,
  detailed: 6,
  source: 7,
  stage: 8,
  description: 9,
  mandateState: 10,
  http: 11,
  amount: 12,
  rung: 13,
  expireAt: 14,
  occurredAt: 15,
  observedBy: 16,
} as const;

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

describe("recordOrderOutcome never throws into the billing write it follows", () => {
  it("resolves when the insert rejects (table missing, connection lost)", async () => {
    const { sql } = capture(() => Promise.reject(new Error('relation "order_outcomes" does not exist')));
    await expect(
      recordOrderOutcome(sql as never, {
        event: "minted",
        observedBy: "pass_a",
        merchantOrderId: "DKS_R_A",
        userId: "u-1",
      }),
    ).resolves.toBeUndefined();
  });

  it("resolves when the driver throws synchronously while building the query", async () => {
    const { sql } = capture(() => {
      throw new TypeError("UNDEFINED_VALUE");
    });
    await expect(
      recordOrderOutcome(sql as never, {
        event: "reconciled",
        observedBy: "pass_b",
        merchantOrderId: "DKS_R_A",
        userId: "u-1",
      }),
    ).resolves.toBeUndefined();
  });

  it("resolves on garbage input and writes nothing without an order id or a user", async () => {
    const { sql, calls } = capture();
    await recordOrderOutcome(sql as never, {
      event: "closed",
      observedBy: "close_sweep",
      merchantOrderId: undefined,
      userId: "u-1",
    });
    await recordOrderOutcome(sql as never, {
      event: "closed",
      observedBy: "close_sweep",
      merchantOrderId: "DKS_R_A",
      userId: null,
      order: "not an object",
      error: 42,
    });
    expect(calls).toHaveLength(0);
  });
});

describe("recordOrderOutcome writes what PhonePe said", () => {
  it("binds only strings, numbers and nulls — postgres.js throws on undefined", async () => {
    const { sql, calls } = capture();
    await recordOrderOutcome(sql as never, {
      event: "minted",
      observedBy: "pass_a",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
    });
    expect(calls).toHaveLength(1);
    for (const v of calls[0].values) expect(v === null || ["string", "number"].includes(typeof v)).toBe(true);
    expect(calls[0].text).toContain("ON CONFLICT DO NOTHING");
  });

  it("takes errorContext's source, stage and description, and the newest attempt's time", async () => {
    const { sql, calls } = capture();
    await recordOrderOutcome(sql as never, {
      event: "closed",
      observedBy: "close_sweep",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
      mandateId: "DKS_S_A",
      retryRung: 2,
      order: {
        state: "FAILED",
        amount: 19900,
        expireAt: 1_791_843_397_828,
        errorCode: "INSUFFICIENT_BALANCE",
        detailedErrorCode: "Z9",
        errorContext: {
          errorCode: "INSUFFICIENT_BALANCE",
          detailedErrorCode: "Z9",
          source: "CUSTOMER",
          stage: "AUTHORIZATION",
          description: "Payment failed due to insufficient balance in customer's account.",
        },
        paymentDetails: [
          { state: "FAILED", timestamp: 1_791_671_409_655 },
          { state: "FAILED", timestamp: 1_791_700_000_000 },
        ],
      },
    });
    const v = calls[0].values;
    expect(v[COL.event]).toBe("closed");
    expect(v[COL.state]).toBe("FAILED");
    expect(v[COL.code]).toBe("INSUFFICIENT_BALANCE");
    expect(v[COL.detailed]).toBe("Z9");
    expect(v[COL.source]).toBe("CUSTOMER");
    expect(v[COL.stage]).toBe("AUTHORIZATION");
    expect(v[COL.amount]).toBe(19900);
    expect(v[COL.rung]).toBe(2);
    expect(v[COL.expireAt]).toBe(new Date(1_791_843_397_828).toISOString());
    expect(v[COL.occurredAt]).toBe(new Date(1_791_700_000_000).toISOString());
  });

  it("keeps a skipped debit's codes and leaves its attempt time empty", async () => {
    const { sql, calls } = capture();
    await recordOrderOutcome(sql as never, {
      event: "closed",
      observedBy: "close_sweep",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
      mandateState: "REVOKED",
      order: {
        state: "FAILED",
        errorCode: "TXN_NOT_COMPLETED",
        detailedErrorCode: "SUBSCRIPTION_DEBIT_SKIPPED",
        errorContext: { source: "BUSINESS", stage: "CAPTURE", description: "Transaction was skipped" },
        paymentDetails: [],
      },
    });
    const v = calls[0].values;
    expect(v[COL.detailed]).toBe("SUBSCRIPTION_DEBIT_SKIPPED");
    expect(v[COL.source]).toBe("BUSINESS");
    expect(v[COL.mandateState]).toBe("REVOKED");
    expect(v[COL.occurredAt]).toBeNull();
  });

  it("reads a refused call's status and code from PhonePe's error body", async () => {
    const { sql, calls } = capture();
    const err = Object.assign(new Error("PhonePe execute error 400"), {
      status: 400,
      body: '{"success":false,"code":"INVALID_SUBSCRIPTION_STATE","message":"Subscription is not active"}',
    });
    await recordOrderOutcome(sql as never, {
      event: "redeem_rejected",
      observedBy: "pass_b",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
      error: err,
    });
    const v = calls[0].values;
    expect(v[COL.http]).toBe(400);
    expect(v[COL.code]).toBe("INVALID_SUBSCRIPTION_STATE");
    expect(v[COL.description]).toBe("Subscription is not active");
  });

  it("keeps only the status when the error body is not JSON", async () => {
    const { sql, calls } = capture();
    const err = Object.assign(new Error("PhonePe execute error 502"), {
      status: 502,
      body: "<html>bad gateway",
    });
    await recordOrderOutcome(sql as never, {
      event: "redeem_rejected",
      observedBy: "pass_b",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
      error: err,
    });
    const v = calls[0].values;
    expect(v[COL.http]).toBe(502);
    expect(v[COL.code]).toBeNull();
  });

  it("truncates an oversized description instead of failing the insert", async () => {
    const { sql, calls } = capture();
    await recordOrderOutcome(sql as never, {
      event: "closed",
      observedBy: "close_sweep",
      merchantOrderId: "DKS_R_A",
      userId: "u-1",
      order: { state: "FAILED", errorContext: { description: "x".repeat(5000) } },
    });
    expect(String(calls[0].values[COL.description])).toHaveLength(300);
  });
});

describe("pruneOrderOutcomes — the owner's 12-month retention", () => {
  it("deletes rows older than 12 months and closes its connection", async () => {
    const { sql, calls } = capture(() => Promise.resolve([{ id: 1 }, { id: 2 }]));
    db.getDb.mockReturnValue(sql);
    await expect(pruneOrderOutcomes({} as Env)).resolves.toBe(2);
    expect(calls[0].text).toContain("DELETE FROM order_outcomes");
    expect(calls[0].text).toContain("interval '12 months'");
    expect(sql.end).toHaveBeenCalled();
  });
});
