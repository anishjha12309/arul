/**
 * Unit tests for lib/meta.ts — server-side Meta Subscribe (Conversions API).
 * Mocks postgres.js, KV, and global fetch — no network, no live DB.
 *
 * The invariant under test everywhere: reportMetaFirstConversion NEVER throws.
 * It runs inside billing state transitions (webhook + autopay cron), where an
 * analytics failure must not cost a user their paid month.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  reportMetaFirstConversion,
  normalizeMetaAnonId,
  normalizeMetaName,
  splitDisplayName,
} from "../src/lib/meta.js";
import type { Env } from "../src/env.js";
import type postgres from "postgres";

const ANON = "XZ12345678-1234-1234-1234-123456789012";
const EMAIL = "Converted.User@Gmail.com";
/** sha256("converted.user@gmail.com") — lib must lowercase+trim before hashing. */
const EMAIL_SHA256 =
  "c4e7a5a372d2a4f2ec8a5f99ee0b211bddfecde24f75f00dd0c1aadd44fda0aa";

/** sha256("maryjane") / sha256("smith") — the fn/ln of "Mary-Jane O'Neil Smith"
 * after Meta's normalisation (lowercase, ASCII punctuation + whitespace
 * stripped; first token → fn, LAST token → ln). */
const FN_SHA256 = "f08f448a5e7a9dc3619bb7c129f6a7d5fc6af002cea17ad71dfdc1c68f4d4e0e";
const LN_SHA256 = "6627835f988e2c5e50533d491163072d3f4f41f5c8b04630150debb3722ca2dd";

function makeMockSql(rows: unknown[]): postgres.Sql {
  return vi.fn().mockResolvedValue(rows) as unknown as postgres.Sql;
}

function makeEnv(overrides: Partial<Record<string, unknown>> = {}): Env {
  const store = new Map<string, string>();
  return {
    META_DATASET_ID: "1234567890",
    META_CAPI_ACCESS_TOKEN: "test-token",
    KV: {
      get: vi.fn(async (k: string) => store.get(k) ?? null),
      put: vi.fn(async (k: string, v: string) => void store.set(k, v)),
    },
    ...overrides,
  } as unknown as Env;
}

const CONVERSION = { userId: "user-1", transactionId: "DKS_x_R_1", amountPaise: 19900 };

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ events_received: 1 }), { status: 200 }),
  );
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("normalizeMetaAnonId", () => {
  it("accepts the Android SDK's XZ+UUID shape and trims", () => {
    expect(normalizeMetaAnonId(` ${ANON} `)).toBe(ANON);
  });
  it("rejects junk, too-short, and non-strings", () => {
    expect(normalizeMetaAnonId("short")).toBeNull();
    expect(normalizeMetaAnonId("has spaces in it")).toBeNull();
    expect(normalizeMetaAnonId(null)).toBeNull();
    expect(normalizeMetaAnonId(42)).toBeNull();
  });
});

describe("normalizeMetaName / splitDisplayName", () => {
  // Expected values come from running Meta's own capi-param-builder
  // (nodejs stringUtil.getNormalizedName) on the same inputs, 2026-08-25.
  it("matches Meta's param-builder normalisation", () => {
    expect(normalizeMetaName("Mary-Jane O'Neil")).toBe("maryjaneoneil");
    expect(normalizeMetaName("  Anish  Kumar J ")).toBe("anishkumarj");
    expect(normalizeMetaName("a[b]c^d\e_f`g{h}i~j")).toBe("abcdefghij");
    // Non-Latin scripts pass through untouched (the reference strips ASCII only).
    expect(normalizeMetaName("ஆனந்த்")).toBe("ஆனந்த்");
    expect(normalizeMetaName("---")).toBeNull();
    expect(normalizeMetaName("")).toBeNull();
    expect(normalizeMetaName(null)).toBeNull();
  });

  it("splits a Google display_name into first token → fn, last token → ln", () => {
    expect(splitDisplayName("Mary-Jane O'Neil Smith")).toEqual({ fn: "maryjane", ln: "smith" });
    expect(splitDisplayName("Anish")).toEqual({ fn: "anish", ln: null });
    expect(splitDisplayName("  ")).toEqual({ fn: null, ln: null });
    expect(splitDisplayName(null)).toEqual({ fn: null, ln: null });
  });
});

describe("reportMetaFirstConversion", () => {
  it("POSTs a system_generated Subscribe with hashed em/external_id and NO device block", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("https://graph.facebook.com/v25.0/1234567890/events");
    expect(url).toContain("access_token=test-token");
    const body = JSON.parse(init.body as string);
    expect(body.data).toHaveLength(1);
    const event = body.data[0];
    expect(event.event_name).toBe("Subscribe");
    // Meta's own definition of system_generated: "a subscription renewal
    // that's set to auto-pay each month". action_source "app" was rejected
    // live (extinfo needs a real OS version the server does not have).
    expect(event.action_source).toBe("system_generated");
    // event_id = merchant order id — the cross-channel dedup key.
    expect(event.event_id).toBe("DKS_x_R_1");
    expect(event.user_data.em).toEqual([EMAIL_SHA256]);
    expect(event.user_data.external_id).toHaveLength(1);
    expect(event.user_data.external_id[0]).toMatch(/^[0-9a-f]{64}$/);
    expect(event.user_data.anon_id).toBeUndefined();
    // No display_name in the row → no fn/ln keys at all (never empty arrays).
    expect(event.user_data.fn).toBeUndefined();
    expect(event.user_data.ln).toBeUndefined();
    expect(event.custom_data).toEqual({
      currency: "INR",
      value: 199,
      order_id: "DKS_x_R_1",
    });
    // No app_data at all — an extinfo with a blank OS version is what Meta
    // bounced (error_subcode 2804043) on the first three real conversions.
    expect(event.app_data).toBeUndefined();
  });

  it("adds hashed fn/ln from display_name (the only extra key with no new Play declaration)", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL, display_name: "Mary-Jane O'Neil Smith" }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const event = JSON.parse(init.body as string).data[0];
    expect(event.user_data.fn).toEqual([FN_SHA256]);
    expect(event.user_data.ln).toEqual([LN_SHA256]);
    // Nothing Play-declarable was added alongside the name.
    expect(event.user_data.client_ip_address).toBeUndefined();
    expect(event.user_data.client_user_agent).toBeUndefined();
    expect(event.user_data.ct).toBeUndefined();
  });

  it("sends fn only for a single-token display_name", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL, display_name: "Anish" }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const event = JSON.parse(init.body as string).data[0];
    expect(event.user_data.fn).toHaveLength(1);
    expect(event.user_data.ln).toBeUndefined();
  });

  it("marks the transaction in KV on success and skips a repeat report", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);
    await reportMetaFirstConversion(env, sql, CONVERSION); // webhook + cron double-settle

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(env.KV.put).toHaveBeenCalledWith(
      "meta:subscribe:DKS_x_R_1",
      "1",
      expect.objectContaining({ expirationTtl: expect.any(Number) }),
    );
  });

  it("does NOT mark KV when Graph rejects the request, so a retry can succeed", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "bad token" } }), { status: 400 }),
    );
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("skips silently when Meta config is absent (tests / unconfigured envs)", async () => {
    const env = makeEnv({ META_CAPI_ACCESS_TOKEN: undefined });
    const sql = makeMockSql([{ email: EMAIL }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(sql).not.toHaveBeenCalled(); // config check must precede any DB read
  });

  it("skips when the user has no email (nothing to match on)", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: null }]);

    await reportMetaFirstConversion(env, sql, CONVERSION);

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("falls back to ₹199 when the payload omitted the amount", async () => {
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL }]);

    await reportMetaFirstConversion(env, sql, { ...CONVERSION, amountPaise: null });

    const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
    expect(body.data[0].custom_data.value).toBe(199);
  });

  it("never throws — fetch failure", async () => {
    fetchMock.mockRejectedValue(new Error("network down"));
    const env = makeEnv();
    const sql = makeMockSql([{ email: EMAIL }]);

    await expect(reportMetaFirstConversion(env, sql, CONVERSION)).resolves.toBeUndefined();
  });

  it("never throws — DB failure", async () => {
    const env = makeEnv();
    const sql = vi.fn().mockRejectedValue(new Error("db down")) as unknown as postgres.Sql;

    await expect(reportMetaFirstConversion(env, sql, CONVERSION)).resolves.toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("never throws — KV failure", async () => {
    const env = makeEnv();
    (env.KV.get as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("kv down"));
    const sql = makeMockSql([{ email: EMAIL }]);

    await expect(reportMetaFirstConversion(env, sql, CONVERSION)).resolves.toBeUndefined();
  });
});
