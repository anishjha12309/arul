/**
 * Unit tests for entitlement logic.
 * Mocks the postgres.js Sql object — no live DB.
 */

import { describe, it, expect, vi } from "vitest";
import { isPremium } from "../src/lib/entitlement.js";
import type postgres from "postgres";

function makeMockSql(rows: unknown[]): postgres.Sql {
  // Return a tagged-template-literal compatible mock
  const mock = vi.fn().mockResolvedValue(rows);
  return mock as unknown as postgres.Sql;
}

describe("entitlement.isPremium", () => {
  it("returns true when there is an active subscription within current_period_end", async () => {
    const sql = makeMockSql([{ "1": 1 }]); // one row = active
    const result = await isPremium(sql, "user-uuid-123");
    expect(result).toBe(true);
  });

  it("returns false when no matching row exists", async () => {
    const sql = makeMockSql([]); // zero rows = not premium
    const result = await isPremium(sql, "user-uuid-123");
    expect(result).toBe(false);
  });

  it("counts 'cancelled' (within period) as premium in the query", async () => {
    const mockFn = vi.fn().mockResolvedValue([{ "1": 1 }]);
    const sql = mockFn as unknown as postgres.Sql;
    await isPremium(sql, "user-uuid-123");
    // The tagged-template strings are the first arg; assert the status set.
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("'cancelled'");
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).not.toContain("'expired'");
  });

  it("has NO allow-list bypass — premium comes solely from the DB", async () => {
    // The former PREMIUM_TEST_USER_IDS override was removed 2026-07-01 so a
    // declined/failed payment can never grant access. isPremium takes only
    // (sql, userId): the DB query is the single source of truth and ALWAYS runs.
    expect(isPremium.length).toBe(2);
    const mockFn = vi.fn().mockResolvedValue([]); // DB says NOT premium
    const sql = mockFn as unknown as postgres.Sql;
    const result = await isPremium(sql, "any-user");
    expect(result).toBe(false);
    expect(mockFn).toHaveBeenCalled(); // never short-circuits
  });

  it("also honors the referral reward pool (users.reward_premium_until)", async () => {
    // A referrer with no subscription but unexpired reward credit is premium.
    const mockFn = vi.fn().mockResolvedValue([{ "1": 1 }]);
    const sql = mockFn as unknown as postgres.Sql;
    const result = await isPremium(sql, "referrer-uuid");
    expect(result).toBe(true);
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("reward_premium_until");
    // Still gates the subscription branch on the same three statuses.
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).toContain("'cancelled'");
  });

  it("passes userId as a parameterized argument", async () => {
    const userId = "user-abc";
    const mockFn = vi.fn().mockResolvedValue([{ "1": 1 }]);
    const sql = mockFn as unknown as postgres.Sql;

    await isPremium(sql, userId);

    // The tagged template call passes strings + values; userId should be in values
    const callArgs = mockFn.mock.calls[0] as unknown[];
    const argsStr = JSON.stringify(callArgs);
    expect(argsStr).toContain(userId);
  });
});
