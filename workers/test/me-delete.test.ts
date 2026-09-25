/**
 * DELETE /me — money and PII, in a fixed order: revoke → tombstone → cascade → refresh-jti denylist.
 *
 * A mandate that outlives its account keeps debiting a person who no longer exists; a missing
 * tombstone re-opens trial farming; a split tombstone/delete loses the guard; a live refresh token
 * resurrects a session. Each is pinned here against a sequenced SQL mock.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleDeleteAccount } from "../src/routes/me.js";
import { signAccessToken, signRefreshToken, isJtiDenylisted } from "../src/lib/jwt.js";
import { makeCtx, makeEnv } from "./_ctx.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

const revoke = vi.fn<(env: unknown, id: string) => Promise<boolean>>();
vi.mock("../src/lib/phonepe.js", () => ({
  revokeMandateTolerant: (env: unknown, id: string) => revoke(env, id),
}));

const reportCancel = vi.fn(async () => {});
vi.mock("../src/lib/posthog.js", () => ({
  reportPostHogSubscriptionCancel: (...args: unknown[]) => reportCancel(...(args as [])),
}));

const USER_ID = "11111111-1111-1111-1111-111111111111";
const TOMBSTONE_SECRET = "test-tombstone-secret";

type Call = { text: string; values: unknown[]; inTx: boolean };

/** A tagged-template SQL mock: the FIRST query answers [row]; every call is logged in order. */
function makeSql(row: Record<string, unknown> | null) {
  const calls: Call[] = [];
  let reads = 0;
  const tag =
    (inTx: boolean) =>
    (strings: TemplateStringsArray, ...values: unknown[]) => {
      calls.push({ text: strings.join("?"), values, inTx });
      if (!inTx && reads++ === 0) return Promise.resolve(row ? [row] : []);
      return Promise.resolve([]);
    };
  const sql = Object.assign(tag(false), {
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(tag(true))),
    end: vi.fn().mockResolvedValue(undefined),
  });
  return { sql, calls };
}

async function run(row: Record<string, unknown> | null, withRefresh = true) {
  const { sql, calls } = makeSql(row);
  const env = makeEnv({ _testSql: sql, TRIAL_TOMBSTONE_SECRET: TOMBSTONE_SECRET });
  const token = await signAccessToken(USER_ID, env.JWT_SECRET);
  const refresh = await signRefreshToken(USER_ID, env.JWT_SECRET);
  const ctx = makeCtx({
    env,
    token,
    jsonBody: withRefresh ? { refreshToken: refresh.token } : {},
  });
  const res = await handleDeleteAccount(ctx);
  return { res, calls, env, sql, jti: refresh.jti };
}

const trialing = {
  google_sub: "google-123",
  status: "trialing",
  merchant_subscription_id: "DKS_SUB_1",
  superseded_mandate_id: null,
  trial_end: new Date("2026-10-01T00:00:00Z"),
};

beforeEach(() => {
  revoke.mockReset();
  revoke.mockResolvedValue(true);
  reportCancel.mockClear();
});

describe("DELETE /me", () => {
  it("revokes, tombstones and cascades in one transaction, then denylists the refresh jti", async () => {
    const { res, calls, env, jti } = await run(trialing);
    expect(res.status).toBe(200);
    expect(revoke).toHaveBeenCalledWith(expect.anything(), "DKS_SUB_1");
    expect(reportCancel).toHaveBeenCalledTimes(1);

    const tx = calls.filter((c) => c.inTx);
    expect(tx).toHaveLength(2);
    expect(tx[0].text).toContain("INSERT INTO trial_tombstones");
    expect(tx[0].text).toContain("ON CONFLICT (google_sub_hash) DO NOTHING");
    expect(tx[0].values[0]).not.toBe("google-123");
    expect(tx[0].values[1]).toEqual(trialing.trial_end);
    expect(tx[1].text).toContain("DELETE FROM users");
    expect(tx[1].values).toEqual([USER_ID]);

    expect(await isJtiDenylisted(env.KV, jti)).toBe(true);
  });

  it("the tombstone hash is stable for a google sub, so a re-signup finds it", async () => {
    const a = await run(trialing);
    const b = await run(trialing);
    const hash = (r: { calls: Call[] }) => r.calls.find((c) => c.inTx)!.values[0];
    expect(hash(a)).toBe(hash(b));
    expect(typeof hash(a)).toBe("string");
  });

  it("a failed revoke deletes NOTHING and asks for a retry", async () => {
    revoke.mockResolvedValue(false);
    const { res, calls, env, jti } = await run(trialing);
    expect(res.status).toBe(502);
    expect(calls.filter((c) => c.inTx)).toHaveLength(0);
    expect(reportCancel).not.toHaveBeenCalled();
    expect(await isJtiDenylisted(env.KV, jti)).toBe(false);
  });

  it("a parked mandate dies with the account too", async () => {
    await run({ ...trialing, superseded_mandate_id: "DKS_SUB_OLD" });
    expect(revoke.mock.calls.map((c) => c[1])).toEqual(["DKS_SUB_1", "DKS_SUB_OLD"]);
  });

  it("a parked-mandate revoke failure also blocks the delete", async () => {
    revoke.mockImplementation(async (_e, id) => id !== "DKS_SUB_OLD");
    const { res, calls } = await run({ ...trialing, superseded_mandate_id: "DKS_SUB_OLD" });
    expect(res.status).toBe(502);
    expect(calls.filter((c) => c.inTx)).toHaveLength(0);
  });

  it.each(["cancelled", "expired"])("a %s row revokes nothing", async (status) => {
    const { res } = await run({ ...trialing, status });
    expect(res.status).toBe(200);
    expect(revoke).not.toHaveBeenCalled();
    expect(reportCancel).not.toHaveBeenCalled();
  });

  it("a pending row IS revoked: setup can complete after the read", async () => {
    await run({ ...trialing, status: "pending" });
    expect(revoke).toHaveBeenCalledTimes(1);
  });

  it("no consumed trial means no tombstone, still a cascade", async () => {
    const { res, calls } = await run({
      google_sub: "google-123",
      status: null,
      merchant_subscription_id: null,
      superseded_mandate_id: null,
      trial_end: null,
    });
    expect(res.status).toBe(200);
    const tx = calls.filter((c) => c.inTx);
    expect(tx).toHaveLength(1);
    expect(tx[0].text).toContain("DELETE FROM users");
  });

  it("no refresh token in the body still deletes", async () => {
    const { res, calls } = await run(trialing, false);
    expect(res.status).toBe(200);
    expect(calls.some((c) => c.text.includes("DELETE FROM users"))).toBe(true);
  });

  it("an unknown user is a 404 and touches nothing", async () => {
    const { res, calls } = await run(null);
    expect(res.status).toBe(404);
    expect(calls.filter((c) => c.inTx)).toHaveLength(0);
    expect(revoke).not.toHaveBeenCalled();
  });

  it("every query is scoped to the VERIFIED sub", async () => {
    const { calls } = await run(trialing);
    expect(calls[0].values).toEqual([USER_ID]);
  });

  it("no bearer is a 401", async () => {
    const { sql } = makeSql(trialing);
    const env = makeEnv({ _testSql: sql, TRIAL_TOMBSTONE_SECRET: TOMBSTONE_SECRET });
    const res = await handleDeleteAccount(makeCtx({ env }));
    expect(res.status).toBe(401);
  });
});
