/**
 * Unit tests for entitlement logic.
 * Mocks the postgres.js Sql object — no live DB.
 */

import { describe, it, expect, vi } from "vitest";
import { isPremium, premiumPredicate } from "../src/lib/entitlement.js";
import type postgres from "postgres";

function makeMockSql(rows: unknown[]): postgres.Sql {
  // Return a tagged-template-literal compatible mock
  const mock = vi.fn().mockResolvedValue(rows);
  return mock as unknown as postgres.Sql;
}

/**
 * isPremium now composes premiumPredicate as a nested tagged-template call, so
 * the SQL text is spread across the mock's calls. Join everything to assert on
 * the full statement regardless of composition.
 */
function allQueryText(mockFn: ReturnType<typeof vi.fn>): string {
  return mockFn.mock.calls
    .map((call) => ((call as unknown[])[0] as string[]).join(""))
    .join(" ");
}

describe("entitlement.isPremium", () => {
  it("returns true when the predicate evaluates true (live sub in period)", async () => {
    const sql = makeMockSql([{ ok: true }]); // SELECT <predicate> AS ok
    const result = await isPremium(sql, "user-uuid-123");
    expect(result).toBe(true);
  });

  it("returns false when the predicate evaluates false", async () => {
    const sql = makeMockSql([{ ok: false }]);
    const result = await isPremium(sql, "user-uuid-123");
    expect(result).toBe(false);
  });

  it("returns false (never throws) if the query yields no row at all", async () => {
    const sql = makeMockSql([]); // defensive: fail closed, not open
    const result = await isPremium(sql, "user-uuid-123");
    expect(result).toBe(false);
  });

  it("counts 'cancelled' (within period) as premium in the query", async () => {
    const mockFn = vi.fn().mockResolvedValue([{ ok: true }]);
    const sql = mockFn as unknown as postgres.Sql;
    await isPremium(sql, "user-uuid-123");
    const query = allQueryText(mockFn);
    expect(query).toContain("'cancelled'");
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).not.toContain("'expired'");
  });

  it("exposes the rule as ONE composable fragment (premiumPredicate)", async () => {
    // Callers like /media/signed-url inline this fragment instead of copying
    // the rule — assert the exported fragment itself carries the whole rule.
    const mockFn = vi.fn().mockResolvedValue([]);
    const sql = mockFn as unknown as postgres.Sql;
    await premiumPredicate(sql, "user-uuid-123");
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("EXISTS");
    expect(query).toContain("reward_premium_until");
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).toContain("'cancelled'");
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
    const mockFn = vi.fn().mockResolvedValue([{ ok: true }]);
    const sql = mockFn as unknown as postgres.Sql;
    const result = await isPremium(sql, "referrer-uuid");
    expect(result).toBe(true);
    const query = allQueryText(mockFn);
    expect(query).toContain("reward_premium_until");
    // Still gates the subscription branch on the same three statuses.
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).toContain("'cancelled'");
  });

  it("passes userId as a parameterized argument", async () => {
    const userId = "user-abc";
    const mockFn = vi.fn().mockResolvedValue([{ ok: true }]);
    const sql = mockFn as unknown as postgres.Sql;

    await isPremium(sql, userId);

    // The tagged template call passes strings + values; userId should be in
    // values (it rides inside the premiumPredicate fragment call).
    const argsStr = JSON.stringify(mockFn.mock.calls);
    expect(argsStr).toContain(userId);
  });
});
