/**
 * Unit tests for referral logic:
 *   - generateReferralCode (issued on first login)
 *   - normalizeReferralCode
 *   - captureReferral   (link referrer + open pending row on signup)
 *   - grantReferralReward (credit referrer on first paid debit, idempotent)
 *
 * Mocks the postgres.js Sql object — no live DB. Multi-statement helpers use a
 * sequenced mock so each tagged-template call returns its own queued response.
 */

import { describe, it, expect, vi } from "vitest";
import {
  generateReferralCode,
  normalizeReferralCode,
  captureReferral,
  grantReferralReward,
  REWARD_DAYS,
} from "../src/lib/referral.js";
import type postgres from "postgres";

/**
 * Build a mock Sql that returns `queue[i]` for the i-th tagged-template call and
 * records each call's concatenated query string + interpolated values.
 */
function makeSequencedSql(queue: unknown[][]) {
  let i = 0;
  const calls: { query: string; values: unknown[] }[] = [];
  const fn = vi.fn((strings: TemplateStringsArray, ...values: unknown[]) => {
    calls.push({ query: strings.join("?"), values });
    return Promise.resolve(queue[i++] ?? []);
  });
  return { sql: fn as unknown as postgres.Sql, calls, count: () => i };
}

describe("generateReferralCode", () => {
  it("is 8 chars from the unambiguous alphabet", () => {
    const code = generateReferralCode();
    expect(code).toHaveLength(8);
    expect(code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
  });

  it("never contains the ambiguous characters O, 0, I, or 1", () => {
    for (let i = 0; i < 500; i++) {
      expect(generateReferralCode()).not.toMatch(/[O0I1]/);
    }
  });

  it("produces distinct codes across many calls (no obvious repeats)", () => {
    const codes = new Set<string>();
    for (let i = 0; i < 200; i++) codes.add(generateReferralCode());
    // 32^8 keyspace → 200 draws colliding is astronomically unlikely.
    expect(codes.size).toBe(200);
  });
});

describe("normalizeReferralCode", () => {
  it("trims and uppercases", () => {
    expect(normalizeReferralCode("  abc123  ")).toBe("ABC123");
  });
  it("collapses blank to empty string", () => {
    expect(normalizeReferralCode("   ")).toBe("");
  });
});

describe("REWARD_DAYS", () => {
  it("is 30 days", () => {
    expect(REWARD_DAYS).toBe(30);
  });
});

describe("captureReferral", () => {
  it("returns null and writes nothing for an unknown code", async () => {
    const { sql, count } = makeSequencedSql([[]]); // SELECT → no referrer
    const result = await captureReferral(sql, "new-user", "BADCODE1");
    expect(result).toBeNull();
    expect(count()).toBe(1); // only the SELECT ran; no UPDATE/INSERT
  });

  it("returns null for a blank code without touching the DB", async () => {
    const { sql, count } = makeSequencedSql([]);
    const result = await captureReferral(sql, "new-user", "   ");
    expect(result).toBeNull();
    expect(count()).toBe(0);
  });

  it("links the referrer and opens a pending row for a valid code", async () => {
    const { sql, calls, count } = makeSequencedSql([
      [{ id: "referrer-1" }], // SELECT referrer
      [], // UPDATE users.referred_by
      [], // INSERT referrals
    ]);
    const result = await captureReferral(sql, "new-user", " code1234 ");
    expect(result).toBe("referrer-1");
    expect(count()).toBe(3);
    // Code is normalized (uppercased) before the lookup, and self-referral is
    // excluded via id <> newUserId.
    expect(calls[0].values).toContain("CODE1234");
    expect(calls[0].values).toContain("new-user");
    // referred_by is set to the referrer for the new user.
    expect(calls[1].query).toContain("referred_by");
    expect(calls[1].values).toEqual(
      expect.arrayContaining(["referrer-1", "new-user"]),
    );
    // A pending referrals row is opened idempotently.
    expect(calls[2].query).toContain("INSERT INTO referrals");
    expect(calls[2].query).toContain("ON CONFLICT");
  });
});

describe("grantReferralReward", () => {
  it("credits the referrer when a referral flips to rewarded", async () => {
    const { sql, calls, count } = makeSequencedSql([
      [{ referrer_id: "referrer-1" }], // UPDATE referrals RETURNING (changed a row)
      [], // UPDATE users.reward_premium_until
    ]);
    await grantReferralReward(sql, "referred-1");
    expect(count()).toBe(2);
    // First statement flips status with the reward guard.
    expect(calls[0].query).toContain("status = 'rewarded'");
    expect(calls[0].query).toContain("status <> 'rewarded'");
    expect(calls[0].values).toContain("referred-1");
    expect(calls[0].values).toContain(REWARD_DAYS);
    // Second statement extends the referrer's reward pool.
    expect(calls[1].query).toContain("reward_premium_until");
    expect(calls[1].values).toContain("referrer-1");
    expect(calls[1].values).toContain(REWARD_DAYS);
  });

  it("is a no-op when already rewarded / not referred (guard returns 0 rows)", async () => {
    const { sql, count } = makeSequencedSql([
      [], // UPDATE referrals RETURNING → nothing changed
    ]);
    await grantReferralReward(sql, "referred-1");
    expect(count()).toBe(1); // never touches users.reward_premium_until
  });
});
