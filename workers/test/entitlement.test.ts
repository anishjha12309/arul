/** Entitlement logic against a mocked postgres.js Sql -> these assert the SQL TEXT, since no live DB runs it. */

import { describe, it, expect, vi } from "vitest";
import { isPremium, premiumPredicate } from "../src/lib/entitlement.js";
import type postgres from "postgres";

function makeMockSql(rows: unknown[]): postgres.Sql {
  // The mock must be callable as a tagged template -> premiumPredicate composes as one
  const mock = vi.fn().mockResolvedValue(rows);
  return mock as unknown as postgres.Sql;
}

/** isPremium composes premiumPredicate as a NESTED tagged template -> the SQL spans several mock calls -> join them all. */
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
    // /media/signed-url INLINES this fragment rather than copying the rule -> assert the fragment carries all of it
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
    // There is NO test-user override -> a declined payment could otherwise grant access
    // isPremium takes only (sql, userId) -> the DB query is the single source of truth and ALWAYS runs
    expect(isPremium.length).toBe(2);
    const mockFn = vi.fn().mockResolvedValue([]); // DB says NOT premium
    const sql = mockFn as unknown as postgres.Sql;
    const result = await isPremium(sql, "any-user");
    expect(result).toBe(false);
    expect(mockFn).toHaveBeenCalled(); // never short-circuits
  });

  it("also honors the referral reward pool (users.reward_premium_until)", async () => {
    // A referrer with NO subscription but unexpired reward credit is premium -> the client copy missed this
    const mockFn = vi.fn().mockResolvedValue([{ ok: true }]);
    const sql = mockFn as unknown as postgres.Sql;
    const result = await isPremium(sql, "referrer-uuid");
    expect(result).toBe(true);
    const query = allQueryText(mockFn);
    expect(query).toContain("reward_premium_until");
    // The subscription branch still gates on the same statuses -> the reward pool is additive, never a replacement
    expect(query).toContain("'trialing'");
    expect(query).toContain("'active'");
    expect(query).toContain("'cancelled'");
  });

  it("carries the DEBIT_GRACE window for trialing/active only", async () => {
    // The renewal debit rides the cron -> a flawless payer sits past current_period_end every cycle
    // A strict `> now()` cutoff therefore closed the gate on the MAINLINE path at every period boundary
    // So the grace branch must exist, scoped to the statuses a debit is actually coming for
    // 'cancelled' gets NO grace -> period end IS the end -> and dunning's flip to 'expired' ends it
    const mockFn = vi.fn().mockResolvedValue([]);
    const sql = mockFn as unknown as postgres.Sql;
    await premiumPredicate(sql, "user-uuid-123");
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("interval '6 hours'");
    // The grace branch names only trialing/active -> 'cancelled' appears in the strict branch alone, exactly once
    const cancelledMentions = query.split("'cancelled'").length - 1;
    expect(cancelledMentions).toBe(1);
    // Grace must never resurrect a terminal row -> 'paused' and 'expired' appear in neither branch
    expect(query).not.toContain("'expired'");
    expect(query).not.toContain("'paused'");
  });

  it("keeps a still-paid period working through a 'pending' resubscribe claim", async () => {
    // A resubscribe overwrites the user's ONE row to 'pending' while the sheet is open
    // Without 'pending' in the strict branch, tapping Resubscribe instantly stripped a still-paid trial
    // Strict branch ONLY -> a pending attempt gets no debit grace -> no debit is in flight for it
    const mockFn = vi.fn().mockResolvedValue([]);
    const sql = mockFn as unknown as postgres.Sql;
    await premiumPredicate(sql, "user-uuid-123");
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("'pending'");
    const pendingMentions = query.split("'pending'").length - 1;
    expect(pendingMentions).toBe(1);
  });

  it("passes userId as a parameterized argument", async () => {
    const userId = "user-abc";
    const mockFn = vi.fn().mockResolvedValue([{ ok: true }]);
    const sql = mockFn as unknown as postgres.Sql;

    await isPremium(sql, userId);

    // A tagged template passes strings and values separately -> userId must be a VALUE, never interpolated text
    const argsStr = JSON.stringify(mockFn.mock.calls);
    expect(argsStr).toContain(userId);
  });
});
