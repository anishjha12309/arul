/**
 * END-TO-END referral test against REAL Neon (the actual lib functions + real
 * SQL, not mocks). Skipped unless E2E_NEON=1 so it never runs in normal CI.
 *
 * Run:  E2E_NEON=1 npx vitest run referral.e2e
 *
 * Exercises the full backend loop:
 *   captureReferral → isPremium(false) → grantReferralReward → isPremium(true)
 *   → idempotency → the /me/referrals aggregate query.
 *
 * Creates namespaced throwaway users (google_sub 'e2e-ref-*') and deletes them
 * (cascades referrals/subscriptions) in afterAll.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import path from "node:path";
import postgres from "postgres";
import {
  captureReferral,
  grantReferralReward,
  generateReferralCode,
} from "../src/lib/referral.js";
import { isPremium } from "../src/lib/entitlement.js";

const RUN = process.env.E2E_NEON === "1";

function readDevVar(key: string): string | undefined {
  // vitest runs with cwd = workers/, where .dev.vars lives.
  const devPath = path.join(process.cwd(), ".dev.vars");
  const text = fs.readFileSync(devPath, "utf8");
  const m = text.match(new RegExp(`^${key}=(.*)$`, "m"));
  return m?.[1]?.trim();
}

describe.skipIf(!RUN)("referral E2E (real Neon)", () => {
  let sql: postgres.Sql;
  let referrerId = "";
  let friendId = "";
  const referrerCode = generateReferralCode();
  const stamp = Date.now();

  beforeAll(async () => {
    const conn = readDevVar("WRANGLER_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE");
    if (!conn) throw new Error("Neon connection string not found in .dev.vars");
    sql = postgres(conn, { max: 2, fetch_types: false });

    // Fresh slate for this run.
    await sql`DELETE FROM users WHERE google_sub LIKE 'e2e-ref-%'`;

    const [referrer] = await sql<{ id: string }[]>`
      INSERT INTO users (google_sub, email, display_name, referral_code)
      VALUES (${`e2e-ref-referrer-${stamp}`}, ${`referrer-${stamp}@example.com`},
              ${"Referrer"}, ${referrerCode})
      RETURNING id
    `;
    referrerId = referrer.id;

    const [friend] = await sql<{ id: string }[]>`
      INSERT INTO users (google_sub, email, display_name, referral_code)
      VALUES (${`e2e-ref-friend-${stamp}`}, ${`amir-${stamp}@example.com`},
              ${""}, ${generateReferralCode()})
      RETURNING id
    `;
    friendId = friend.id;
  });

  afterAll(async () => {
    if (sql) {
      await sql`DELETE FROM users WHERE google_sub LIKE 'e2e-ref-%'`;
      await sql.end();
    }
  });

  it("captureReferral links the friend to the referrer + opens a pending row", async () => {
    // Simulate the code arriving lowercased/with spaces (Play Install Referrer).
    const linked = await captureReferral(sql, friendId, `  ${referrerCode.toLowerCase()}  `);
    expect(linked).toBe(referrerId);

    const [u] = await sql`SELECT referred_by FROM users WHERE id = ${friendId}`;
    expect(u.referred_by).toBe(referrerId);

    const [r] = await sql`
      SELECT status, reward_days FROM referrals WHERE referred_user_id = ${friendId}
    `;
    expect(r.status).toBe("pending");
    expect(Number(r.reward_days)).toBe(0);
  });

  it("captureReferral is a no-op on a second attempt (unique referred_user_id)", async () => {
    // Re-running must not create a duplicate referrals row.
    await captureReferral(sql, friendId, referrerCode);
    const rows = await sql`SELECT id FROM referrals WHERE referred_user_id = ${friendId}`;
    expect(rows.length).toBe(1);
  });

  it("referrer is NOT premium before any reward", async () => {
    expect(await isPremium(sql, referrerId)).toBe(false);
  });

  it("grantReferralReward flips to rewarded and credits the referrer ~30 days", async () => {
    await grantReferralReward(sql, friendId);

    const [r] = await sql`
      SELECT status, reward_days FROM referrals WHERE referred_user_id = ${friendId}
    `;
    expect(r.status).toBe("rewarded");
    expect(Number(r.reward_days)).toBe(30);

    const [u] = await sql<{ days: number }[]>`
      SELECT round(extract(epoch FROM (reward_premium_until - now())) / 86400)::int AS days
      FROM users WHERE id = ${referrerId}
    `;
    // ~30 days out (allow slop for execution time).
    expect(u.days).toBeGreaterThanOrEqual(29);
    expect(u.days).toBeLessThanOrEqual(30);
  });

  it("referrer IS premium via the reward pool (no subscription row)", async () => {
    expect(await isPremium(sql, referrerId)).toBe(true);
    // Prove it comes from the reward pool, not a subscription.
    const subs = await sql`SELECT 1 FROM subscriptions WHERE user_id = ${referrerId}`;
    expect(subs.length).toBe(0);
  });

  it("grantReferralReward is idempotent (a renewal does not add another 30 days)", async () => {
    const [before] = await sql`SELECT reward_premium_until FROM users WHERE id = ${referrerId}`;
    await grantReferralReward(sql, friendId); // simulate a later renewal debit
    const [after] = await sql`SELECT reward_premium_until FROM users WHERE id = ${referrerId}`;
    expect(after.reward_premium_until).toEqual(before.reward_premium_until);
  });

  it("the /me/referrals aggregate reflects the reward (total 30, masked name)", async () => {
    // Mirror the handleMeReferrals query exactly.
    const rows = await sql`
      SELECT r.status, r.reward_days, u.display_name AS referred_name, u.email AS referred_email
      FROM referrals r
      JOIN users u ON u.id = r.referred_user_id
      WHERE r.referrer_id = ${referrerId}
      ORDER BY r.created_at DESC
    `;
    expect(rows.length).toBe(1);
    const total = rows.reduce((s, row) => s + Number(row.reward_days), 0);
    expect(total).toBe(30);
    expect(rows[0].status).toBe("rewarded");
    // Friend has a blank display_name → the API masks the email.
    expect((rows[0].referred_name as string | null) ?? "").toBe("");
    expect(rows[0].referred_email).toContain("@example.com");
  });
});
