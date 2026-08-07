/**
 * Unit tests for lib/ga4.ts — server-side GA4 purchase reporting.
 * Mocks postgres.js, KV, and global fetch — no network, no live DB.
 *
 * The invariant under test everywhere: reportServerPurchase NEVER throws.
 * It runs inside billing state transitions (webhook + autopay cron), where an
 * analytics failure must not cost a user their paid month.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  reportServerPurchase,
  normalizeAppInstanceId,
  APP_INSTANCE_ID_RE,
} from "../src/lib/ga4.js";
import type { Env } from "../src/env.js";
import type postgres from "postgres";

const IID = "0123456789abcdef0123456789abcdef";

function makeMockSql(rows: unknown[]): postgres.Sql {
  return vi.fn().mockResolvedValue(rows) as unknown as postgres.Sql;
}

function makeEnv(overrides: Partial<Record<string, unknown>> = {}): Env {
  const store = new Map<string, string>();
  return {
    GA4_API_SECRET: "test-secret",
    GA4_FIREBASE_APP_ID: "1:123:android:abc",
    KV: {
      get: vi.fn(async (k: string) => store.get(k) ?? null),
      put: vi.fn(async (k: string, v: string) => void store.set(k, v)),
    },
    ...overrides,
  } as unknown as Env;
}

const PURCHASE = { userId: "user-1", transactionId: "DKS_x_R_1", amountPaise: 19900 };

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("normalizeAppInstanceId", () => {
  it("accepts exactly 32 lowercase hex chars", () => {
    expect(normalizeAppInstanceId(IID)).toBe(IID);
  });
  it("lowercases and trims before validating", () => {
    expect(normalizeAppInstanceId(`  ${IID.toUpperCase()}  `)).toBe(IID);
  });
  it("rejects wrong length, non-hex, and non-strings", () => {
    expect(normalizeAppInstanceId(IID.slice(1))).toBeNull();
    expect(normalizeAppInstanceId(`${IID.slice(0, 31)}g`)).toBeNull();
    expect(normalizeAppInstanceId(null)).toBeNull();
    expect(normalizeAppInstanceId(42)).toBeNull();
    expect(APP_INSTANCE_ID_RE.test("")).toBe(false);
  });
});

describe("reportServerPurchase", () => {
  it("POSTs a purchase event keyed on the stored app_instance_id", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await reportServerPurchase(env, sql, PURCHASE);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("https://www.google-analytics.com/mp/collect");
    expect(url).toContain("api_secret=test-secret");
    expect(url).toContain(`firebase_app_id=${encodeURIComponent("1:123:android:abc")}`);
    const body = JSON.parse(init.body as string);
    expect(body.app_instance_id).toBe(IID);
    expect(body.events).toEqual([
      {
        name: "purchase",
        params: { currency: "INR", value: 199, transaction_id: "DKS_x_R_1" },
      },
    ]);
  });

  it("marks the transaction in KV on success and skips a repeat report", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await reportServerPurchase(env, sql, PURCHASE);
    await reportServerPurchase(env, sql, PURCHASE); // webhook + cron double-settle

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(env.KV.put).toHaveBeenCalledWith(
      "ga4:purchase:DKS_x_R_1",
      "1",
      expect.objectContaining({ expirationTtl: expect.any(Number) }),
    );
  });

  it("does NOT mark KV when MP rejects the request, so a retry can succeed", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 400 }));
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await reportServerPurchase(env, sql, PURCHASE);

    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("skips silently when GA4 config is absent (tests / unconfigured envs)", async () => {
    const env = makeEnv({ GA4_API_SECRET: undefined });
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await reportServerPurchase(env, sql, PURCHASE);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(sql).not.toHaveBeenCalled(); // config check must precede any DB read
  });

  it("skips when the user has no stored app_instance_id (pre-upload install)", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: null }]);

    await reportServerPurchase(env, sql, PURCHASE);

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("falls back to ₹199 when the webhook payload omitted the amount", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await reportServerPurchase(env, sql, { ...PURCHASE, amountPaise: null });

    const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
    expect(body.events[0].params.value).toBe(199);
  });

  it("never throws — fetch failure", async () => {
    fetchMock.mockRejectedValue(new Error("network down"));
    const env = makeEnv();
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await expect(reportServerPurchase(env, sql, PURCHASE)).resolves.toBeUndefined();
  });

  it("never throws — DB failure", async () => {
    const env = makeEnv();
    const sql = vi.fn().mockRejectedValue(new Error("db down")) as unknown as postgres.Sql;

    await expect(reportServerPurchase(env, sql, PURCHASE)).resolves.toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("never throws — KV failure", async () => {
    const env = makeEnv();
    (env.KV.get as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("kv down"));
    const sql = makeMockSql([{ app_instance_id: IID }]);

    await expect(reportServerPurchase(env, sql, PURCHASE)).resolves.toBeUndefined();
  });
});
