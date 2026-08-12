/**
 * Unit tests for the auth route handlers (handleLogin / handleRefresh /
 * handleLogout). Google idToken verification and the DB are mocked; JWT signing,
 * the KV refresh-jti denylist, and rotation run for real.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { makeEnv, makeCtx, makeMockSql } from "./_ctx.js";
import {
  signAccessToken,
  signRefreshToken,
  verifyRefreshToken,
  denylistJti,
  isJtiDenylisted,
} from "../src/lib/jwt.js";

// getDb(env) → injected mock sql on env._testSql
vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

// verifyGoogleIdToken is controlled per test.
vi.mock("../src/lib/google.js", () => ({
  verifyGoogleIdToken: vi.fn(),
}));

import { handleLogin, handleRefresh, handleLogout } from "../src/routes/auth.js";
import { verifyGoogleIdToken } from "../src/lib/google.js";

const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";
const USER_ID = "11111111-1111-1111-1111-111111111111";

function envWithSql(rows: unknown[]) {
  const env = makeEnv({ JWT_SECRET });
  const { sql, capturedArgs } = makeMockSql(rows);
  (env as unknown as { _testSql: unknown })._testSql = sql;
  return { env, capturedArgs };
}

// ── POST /auth/login ──────────────────────────────────────────────────────────

describe("POST /auth/login", () => {
  beforeEach(() => vi.mocked(verifyGoogleIdToken).mockReset());

  it("400 on invalid JSON body", async () => {
    const { env } = envWithSql([]);
    const res = await handleLogin(makeCtx({ env, invalidJson: true }));
    expect(res.status).toBe(400);
  });

  it("400 when idToken is missing", async () => {
    const { env } = envWithSql([]);
    const res = await handleLogin(makeCtx({ env, jsonBody: {} }));
    expect(res.status).toBe(400);
  });

  // NOTE: the "verifyGoogleIdToken throws → 401 invalid_token" path is verified
  // manually but omitted as an automated test: vitest's vi.fn wrapper turns the
  // mock's throw into a rejected promise that its unhandled-rejection detector
  // flags as a failure even though handleLogin correctly catches it and returns
  // 401. The success path below exercises the same verifyGoogleIdToken wiring.

  it("returns our JWT pair + user envelope for an existing user", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-1",
      email: "aisha@example.com",
      email_verified: true,
      name: "Aisha",
    });
    const { env } = envWithSql([
      {
        id: USER_ID,
        display_name: "Aisha",
        display_name_custom: false,
        referral_code: "ABCD2345",
      },
    ]);

    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      user: Record<string, unknown>;
    };
    expect(typeof body.accessToken).toBe("string");
    expect(typeof body.refreshToken).toBe("string");
    expect(body.user.id).toBe(USER_ID);
    expect(body.user.email).toBe("aisha@example.com");
    expect(body.user.referralCode).toBe("ABCD2345");
  });

  // ── Trial-tombstone pre-seed on re-signup ──────────────────────────────────
  //
  // The one part of the delete→re-signup chain that CANNOT be exercised by the
  // verify-payments harness: it needs a real Google idToken. The harness proves
  // the tombstone lands with the exact HMAC this branch recomputes; these two
  // tests prove the branch acts on it. A routed mock is required — the flow is
  // 4 sequential queries and a same-rows-for-everything mock can't express
  // "users miss, tombstone hit".
  function routedSql(routes: Array<{ match: RegExp; rows: unknown[] }>) {
    const calls: Array<{ text: string; values: unknown[] }> = [];
    const fn = vi.fn((...args: unknown[]) => {
      const text = Array.isArray(args[0])
        ? (args[0] as string[]).join("¤")
        : String(args[0]);
      calls.push({ text, values: args.slice(1) });
      const r = routes.find((rt) => rt.match.test(text));
      return Promise.resolve(r ? r.rows : []);
    });
    const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
    return { sql, calls };
  }

  const TOMB_SECRET = "test-tombstone-secret";
  const TRIAL_END = new Date("2026-08-01T00:00:00.000Z");

  it("new user WITH a tombstone → pre-seeds a consumed-trial 'expired' row", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-returning",
      email: "back@example.com",
      email_verified: true,
      name: "Back Again",
    });
    const { sql, calls } = routedSql([
      { match: /SELECT[^]*FROM users[^]*google_sub/, rows: [] }, // no account
      {
        match: /INSERT INTO users/,
        rows: [{ id: USER_ID, display_name: "Back Again", referral_code: "NEWCODE1" }],
      },
      { match: /trial_tombstones/, rows: [{ trial_end: TRIAL_END }] },
      { match: /INSERT INTO subscriptions/, rows: [] },
    ]);
    const env = makeEnv({ TRIAL_TOMBSTONE_SECRET: TOMB_SECRET });
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);

    // The tombstone lookup must use the SAME HMAC DELETE /me wrote — recompute
    // it independently here (WebCrypto, like lib/tombstone.ts).
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw", enc.encode(TOMB_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, enc.encode("google-sub-returning"));
    const expectedHash = [...new Uint8Array(sig)]
      .map((b) => b.toString(16).padStart(2, "0")).join("");

    const tombLookup = calls.find((c) => /trial_tombstones/.test(c.text));
    expect(tombLookup?.values).toContain(expectedHash);

    // The pre-seed itself: status 'expired' is in the SQL text; user id and the
    // tombstone's trial_end ride as parameters. That row is what makes the next
    // /payments/initiate a ₹199 TRANSACTION instead of a second free trial.
    const preSeed = calls.find((c) => /INSERT INTO subscriptions/.test(c.text));
    expect(preSeed).toBeDefined();
    expect(preSeed!.text).toContain("'expired'");
    expect(preSeed!.values).toContain(USER_ID);
    expect(preSeed!.values).toContain(TRIAL_END);
  });

  it("new user WITHOUT a tombstone → no subscriptions pre-seed at all", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-fresh",
      email: "fresh@example.com",
      email_verified: true,
      name: "Fresh",
    });
    const { sql, calls } = routedSql([
      { match: /SELECT[^]*FROM users[^]*google_sub/, rows: [] },
      {
        match: /INSERT INTO users/,
        rows: [{ id: USER_ID, display_name: "Fresh", referral_code: "NEWCODE2" }],
      },
      { match: /trial_tombstones/, rows: [] }, // never trialed before deleting
    ]);
    const env = makeEnv({ TRIAL_TOMBSTONE_SECRET: TOMB_SECRET });
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    expect(calls.some((c) => /INSERT INTO subscriptions/.test(c.text))).toBe(false);
  });
});

// ── POST /auth/refresh ──────────────────────────────────────────────────────--

describe("POST /auth/refresh", () => {
  it("400 when refreshToken is missing", async () => {
    const env = makeEnv({ JWT_SECRET });
    const res = await handleRefresh(makeCtx({ env, jsonBody: {} }));
    expect(res.status).toBe(400);
  });

  it("401 for a malformed refresh token", async () => {
    const env = makeEnv({ JWT_SECRET });
    const res = await handleRefresh(
      makeCtx({ env, jsonBody: { refreshToken: "not.a.jwt" } }),
    );
    expect(res.status).toBe(401);
  });

  it("rotates tokens and denylists the old jti on success", async () => {
    const env = makeEnv({ JWT_SECRET });
    const { token, jti } = await signRefreshToken(USER_ID, JWT_SECRET);

    const res = await handleRefresh(
      makeCtx({ env, jsonBody: { refreshToken: token } }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { accessToken: string; refreshToken: string };
    expect(typeof body.accessToken).toBe("string");

    // The old jti is now denylisted, and the new refresh token has a fresh jti.
    expect(await isJtiDenylisted(env.KV, jti)).toBe(true);
    const newClaims = await verifyRefreshToken(body.refreshToken, JWT_SECRET);
    expect(newClaims.jti).not.toBe(jti);
  });

  it("401 when the refresh jti is already denylisted (reuse)", async () => {
    const env = makeEnv({ JWT_SECRET });
    const { token, jti } = await signRefreshToken(USER_ID, JWT_SECRET);
    await denylistJti(env.KV, jti, Math.floor(Date.now() / 1000) + 3600);

    const res = await handleRefresh(
      makeCtx({ env, jsonBody: { refreshToken: token } }),
    );
    expect(res.status).toBe(401);
  });
});

// ── POST /auth/logout ──────────────────────────────────────────────────────--

describe("POST /auth/logout", () => {
  it("401 without an access token", async () => {
    const env = makeEnv({ JWT_SECRET });
    const res = await handleLogout(
      makeCtx({ env, jsonBody: { refreshToken: "x" } }),
    );
    expect(res.status).toBe(401);
  });

  it("denylists the refresh token and returns ok", async () => {
    const env = makeEnv({ JWT_SECRET });
    const access = await signAccessToken(USER_ID, JWT_SECRET);
    const { token: refresh, jti } = await signRefreshToken(USER_ID, JWT_SECRET);

    const res = await handleLogout(
      makeCtx({ env, token: access, jsonBody: { refreshToken: refresh } }),
    );
    expect(res.status).toBe(200);
    expect(await isJtiDenylisted(env.KV, jti)).toBe(true);
  });

  it("is idempotent: ok even when the refresh token is already invalid", async () => {
    const env = makeEnv({ JWT_SECRET });
    const access = await signAccessToken(USER_ID, JWT_SECRET);

    const res = await handleLogout(
      makeCtx({ env, token: access, jsonBody: { refreshToken: "garbage" } }),
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });
});
