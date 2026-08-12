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

  it("carries the DEBIT_GRACE window for trialing/active only", async () => {
    // The renewal debit rides the HOURLY autopay cron, so a flawless payer
    // sits past current_period_end for up to ~1h + settle time every cycle. A
    // strict `> now()` cutoff closed the gate on the mainline path at every
    // period boundary. The grace branch must exist, and must be scoped to the
    // statuses a debit is actually coming for — 'cancelled' gets NO grace
    // (period end IS the end), and dunning's flip to 'expired' ends it.
    const mockFn = vi.fn().mockResolvedValue([]);
    const sql = mockFn as unknown as postgres.Sql;
    await premiumPredicate(sql, "user-uuid-123");
    const strings = (mockFn.mock.calls[0] as unknown[])[0] as string[];
    const query = strings.join("");
    expect(query).toContain("interval '6 hours'");
    // The grace OR-branch names only trialing/active; the strict branch is the
    // only place 'cancelled' appears, so it occurs exactly once in the SQL.
    const cancelledMentions = query.split("'cancelled'").length - 1;
    expect(cancelledMentions).toBe(1);
    // Grace never resurrects terminal rows.
    expect(query).not.toContain("'expired'");
    expect(query).not.toContain("'paused'");
  });

  it("keeps a still-paid period working through a 'pending' resubscribe claim", async () => {
    // A resubscribe overwrites the user's ONE subscriptions row to 'pending'
    // while the sheet is open. Without 'pending' in the strict branch, tapping
    // Resubscribe instantly stripped a cancelled-but-still-paid trial (device
    // 2026-08-12). Strict branch only — a pending attempt gets no debit grace.
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

    // The tagged template call passes strings + values; userId should be in
    // values (it rides inside the premiumPredicate fragment call).
    const argsStr = JSON.stringify(mockFn.mock.calls);
    expect(argsStr).toContain(userId);
  });
});
