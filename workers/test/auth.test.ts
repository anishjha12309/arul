/**
 * The auth route handlers. Google verification and the DB are mocked.
 * JWT signing, the KV refresh-jti denylist and rotation all run FOR REAL -> a failure there is a real break
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

// getDb(env) is replaced -> handlers reach the injected mock sql through env._testSql
vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

// verifyGoogleIdToken is controlled per test -> each case sets the claims it needs
// The error class stays REAL -> handleLogin tells a key outage from a bad token with instanceof
vi.mock("../src/lib/google.js", async (importOriginal) => ({
  GoogleKeysUnavailableError: (await importOriginal<typeof import("../src/lib/google.js")>())
    .GoogleKeysUnavailableError,
  verifyGoogleIdToken: vi.fn(),
}));

import { handleLogin, handleRefresh, handleLogout } from "../src/routes/auth.js";
import { verifyGoogleIdToken, GoogleKeysUnavailableError } from "../src/lib/google.js";

const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";
const USER_ID = "11111111-1111-1111-1111-111111111111";

function envWithSql(rows: unknown[]) {
  const env = makeEnv({ JWT_SECRET, TRIAL_TOMBSTONE_SECRET: "test-tombstone-secret" });
  const { sql, capturedArgs } = makeMockSql(rows);
  (env as unknown as { _testSql: unknown })._testSql = sql;
  return { env, capturedArgs };
}

// ── POST /auth/login ──────────────────────────────────────────────────────────

describe("POST /auth/login", () => {
  // A block body, never an arrow expression -> vitest runs a function returned from beforeEach as teardown
  beforeEach(() => {
    vi.mocked(verifyGoogleIdToken).mockReset();
  });

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

  it("401 invalid_token when Google rejects the token itself", async () => {
    vi.mocked(verifyGoogleIdToken).mockRejectedValue(new Error('"exp" claim timestamp check failed'));
    const { env, capturedArgs } = envWithSql([]);
    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "expired" } }));
    expect(res.status).toBe(401);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_token");
    expect(capturedArgs).toHaveLength(0);
  });

  // A key outage never judged the token -> 401 would tell the app the ACCOUNT is bad
  it("503 google_keys_unavailable when Google's signing keys cannot be fetched", async () => {
    vi.mocked(verifyGoogleIdToken).mockRejectedValue(
      new GoogleKeysUnavailableError("Google JWKS fetch timed out"),
    );
    const { env, capturedArgs } = envWithSql([]);
    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(503);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("google_keys_unavailable");
    expect(capturedArgs).toHaveLength(0);
  });

  it("returns our JWT pair + user envelope for an existing user", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-1",
      email: "aisha@example.com",
      email_verified: true,
      name: "Aisha",
      nonce: undefined,
    });
    const { env } = envWithSql([
      {
        id: USER_ID,
        display_name: "Aisha",
        display_name_custom: false,
        referral_code: "ABCD2345",
        is_internal: false,
        account_age_d: 12,
        sub_status: "expired",
        trial_used: true,
        paid_before: true,
      },
    ]);

    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string;
      refreshToken: string;
      user: Record<string, unknown>;
      analytics: Record<string, unknown>;
    };
    expect(typeof body.accessToken).toBe("string");
    expect(typeof body.refreshToken).toBe("string");
    expect(body.user.id).toBe(USER_ID);
    expect(body.user.email).toBe("aisha@example.com");
    expect(body.user.referralCode).toBe("ABCD2345");
    // A returning account whose trial is spent -> the app stamps this on login_success
    expect(body.analytics).toEqual({
      new_user: false,
      sub_status: "expired",
      trial_used: true,
      account_age_d: 12,
      internal: false,
      paid_before: true,
    });
  });

  it("the login analytics carry the edge's view of the connection after the account facts", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-3",
      email: "jio@example.com",
      email_verified: true,
      name: "Jio",
      nonce: undefined,
    });
    const { env } = envWithSql([
      { id: USER_ID, display_name: "Jio", referral_code: "JIOX2345", is_internal: false },
    ]);
    const res = await handleLogin(
      makeCtx({
        env,
        jsonBody: { idToken: "valid" },
        cf: { asOrganization: "Reliance Jio", clientTcpRtt: 61, colo: "BOM" },
      }),
    );
    const body = (await res.json()) as { analytics: Record<string, unknown> };
    const keys = Object.keys(body.analytics);
    expect(body.analytics).toMatchObject({ isp: "Reliance Jio", rtt_ms: 61, colo: "BOM" });
    expect(keys.indexOf("isp")).toBeGreaterThan(keys.indexOf("paid_before"));
  });

  it("a returning account that never reached checkout reads sub_status none, trial not used", async () => {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub: "google-sub-2",
      email: "ravi@example.com",
      email_verified: true,
      name: "Ravi",
      nonce: undefined,
    });
    const { env } = envWithSql([
      {
        id: USER_ID,
        display_name: "Ravi",
        referral_code: "WXYZ2345",
        is_internal: true,
        sub_status: null,
        trial_used: null,
      },
    ]);
    const res = await handleLogin(makeCtx({ env, jsonBody: { idToken: "valid" } }));
    const body = (await res.json()) as { analytics: Record<string, unknown> };
    expect(body.analytics).toMatchObject({
      new_user: false,
      sub_status: "none",
      trial_used: false,
      internal: true,
    });
  });

  // ── The one-statement upsert and the trial-tombstone pre-seed ─────────────
  // The one part of the delete-then-re-signup chain the verify-payments harness CANNOT reach -> it needs a real idToken
  // The harness proves the tombstone lands with the exact HMAC this branch recomputes -> these prove the branch acts on it
  // A ROUTED mock records each statement's text and values -> the upsert and a retry are told apart
  function routedSql(routes: Array<{ match: RegExp; rows: unknown[] | (() => Promise<unknown[]>) }>) {
    const calls: Array<{ text: string; values: unknown[] }> = [];
    const fn = vi.fn((...args: unknown[]) => {
      const text = Array.isArray(args[0]) ? (args[0] as string[]).join("¤") : String(args[0]);
      calls.push({ text, values: args.slice(1) });
      const r = routes.find((rt) => rt.match.test(text));
      if (!r) return Promise.resolve([]);
      return typeof r.rows === "function" ? r.rows() : Promise.resolve(r.rows);
    });
    const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
    return { sql, calls };
  }

  const TOMB_SECRET = "test-tombstone-secret";
  const TRIAL_END = new Date("2026-08-01T00:00:00.000Z");
  const UPSERT = /INSERT INTO users[\s\S]*ON CONFLICT \(google_sub\) DO UPDATE/;

  function claimsFor(sub: string) {
    vi.mocked(verifyGoogleIdToken).mockResolvedValue({
      sub,
      email: `${sub}@example.com`,
      email_verified: true,
      name: "Name",
      nonce: undefined,
    });
  }

  function envFor(sql: unknown) {
    const env = makeEnv({ TRIAL_TOMBSTONE_SECRET: TOMB_SECRET });
    (env as unknown as { _testSql: unknown })._testSql = sql;
    return env;
  }

  it("new user WITH a tombstone → the SAME statement looks it up and pre-seeds a consumed-trial row", async () => {
    claimsFor("google-sub-returning");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: [
          {
            id: USER_ID,
            display_name: "Back Again",
            referral_code: "NEWCODE1",
            inserted: true,
            tomb_trial_end: TRIAL_END,
          },
        ],
      },
    ]);

    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);

    // The lookup must use the SAME HMAC DELETE /me wrote -> recompute it INDEPENDENTLY here, not via the lib
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      enc.encode(TOMB_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, enc.encode("google-sub-returning"));
    const expectedHash = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");

    // ONE round trip: lookup, upsert and pre-seed are one statement -> a failure anywhere fails the login
    expect(calls).toHaveLength(1);
    const stmt = calls[0]!;
    expect(stmt.text).toMatch(/trial_tombstones/);
    expect(stmt.values).toContain(expectedHash);
    // That row is what makes the next /payments/initiate a ₹199 TRANSACTION instead of a second free trial
    expect(stmt.text).toMatch(/INSERT INTO subscriptions[\s\S]*'expired'[\s\S]*WHERE up\.inserted/);
    // A re-signup after deleting the account is NEW but cannot trial -> it must not count as a trial miss
    expect(((await res.json()) as { analytics: Record<string, unknown> }).analytics).toMatchObject({
      new_user: true,
      sub_status: "expired",
      trial_used: true,
    });
  });

  it("new user WITHOUT a tombstone → new_user analytics, trial still open", async () => {
    claimsFor("google-sub-fresh");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: [
          {
            id: USER_ID,
            display_name: "Fresh",
            referral_code: "NEWCODE2",
            inserted: true,
            tomb_trial_end: null,
          },
        ],
      },
    ]);

    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(1);
    const body = (await res.json()) as { user: Record<string, unknown>; analytics: Record<string, unknown> };
    expect(body.user).toEqual({
      id: USER_ID,
      displayName: "Fresh",
      email: "google-sub-fresh@example.com",
      referralCode: "NEWCODE2",
    });
    expect(body.analytics).toEqual({
      new_user: true,
      sub_status: "none",
      trial_used: false,
      account_age_d: 0,
      internal: false,
      paid_before: false,
    });
  });

  it("the upsert keeps a custom display name and syncs email through EXCLUDED", async () => {
    claimsFor("google-sub-sync");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: [{ id: USER_ID, display_name: "Mine", referral_code: "OLDCODE1", inserted: false }],
      },
    ]);
    await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    const text = calls[0]!.text;
    expect(text).toMatch(/CASE WHEN users\.display_name_custom\s+THEN users\.display_name/);
    expect(text).toMatch(/COALESCE\(EXCLUDED\.display_name, users\.display_name\)/);
    expect(text).toMatch(/email\s+= EXCLUDED\.email/);
    expect(text).toMatch(/\(xmax = 0\) AS inserted/);
  });

  it("a referral-code collision retries the upsert ONCE with a fresh code", async () => {
    claimsFor("google-sub-collide");
    let attempt = 0;
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: () => {
          attempt++;
          if (attempt === 1) {
            return Promise.reject(
              Object.assign(new Error("duplicate key value violates unique constraint"), { code: "23505" }),
            );
          }
          return Promise.resolve([
            {
              id: USER_ID,
              display_name: "C",
              referral_code: "RETRIED1",
              inserted: true,
              tomb_trial_end: null,
            },
          ]);
        },
      },
    ]);
    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(2);
    // The referral code is the INSERT's fifth bound value -> the retry must not resend the colliding one
    const codeOf = (i: number) => calls[i]!.values[4];
    expect(typeof codeOf(0)).toBe("string");
    expect(codeOf(0)).not.toBe(codeOf(1));
  });

  it("a second collision fails the login instead of looping", async () => {
    claimsFor("google-sub-collide-twice");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: () => Promise.reject(Object.assign(new Error("duplicate key"), { code: "23505" })),
      },
    ]);
    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(500);
    expect(calls).toHaveLength(2);
  });

  it("a failed tombstone lookup FAILS the login (fail-closed)", async () => {
    claimsFor("google-sub-dbfail");
    const { sql } = routedSql([{ match: UPSERT, rows: () => Promise.reject(new Error("connection lost")) }]);
    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(500);
  });

  // Fielded builds still send the Install Referrer code -> it must sign in and attribute nothing
  it("a new user sending a referralCode signs in and creates no referrals row", async () => {
    claimsFor("google-sub-referred");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: [
          { id: USER_ID, display_name: "R", referral_code: "NEWCODE3", inserted: true, tomb_trial_end: null },
        ],
      },
    ]);
    const res = await handleLogin(
      makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid", referralCode: "FRIEND23" } }),
    );
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls.some((c) => /referrals|referred_by/.test(c.text))).toBe(false);
    expect(calls.some((c) => c.values.includes("FRIEND23"))).toBe(false);
    const body = (await res.json()) as { user: Record<string, unknown>; analytics: Record<string, unknown> };
    expect(body.user.referralCode).toBe("NEWCODE3");
    expect(body.analytics).not.toHaveProperty("referred");
  });

  // A hedged second POST for a brand-new account lands here too -> the first one owns the pre-seed
  it("a returning user (inserted = false) gets no second statement", async () => {
    claimsFor("google-sub-back");
    const { sql, calls } = routedSql([
      {
        match: UPSERT,
        rows: [
          {
            id: USER_ID,
            display_name: "B",
            referral_code: "OLDCODE2",
            inserted: false,
            tomb_trial_end: TRIAL_END,
            sub_status: "trialing",
            trial_used: true,
            account_age_d: 3,
          },
        ],
      },
    ]);
    const res = await handleLogin(makeCtx({ env: envFor(sql), jsonBody: { idToken: "valid" } }));
    expect(res.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(((await res.json()) as { analytics: Record<string, unknown> }).analytics).toMatchObject({
      new_user: false,
      sub_status: "trialing",
      trial_used: true,
      account_age_d: 3,
    });
  });

  // ── Nonce ──────────────────────────────────────────────────────────────────
  // Google requires the request and response nonces be validated as IDENTICAL
  // The PAIR is checked, not just the request side -> equal-or-nothing is the rule
  // That is what makes a nonce-bearing token unusable through an old-shaped request
  // And what keeps every older install — which sends none, and whose tokens carry none — signing in
  describe("nonce", () => {
    function loginWith(claimNonce: string | undefined, bodyNonce?: string) {
      vi.mocked(verifyGoogleIdToken).mockResolvedValue({
        sub: "google-sub-nonce",
        email: "nonce@example.com",
        email_verified: true,
        name: "Nonce",
        nonce: claimNonce,
      });
      const { env } = envWithSql([
        {
          id: USER_ID,
          display_name: "Nonce",
          display_name_custom: false,
          referral_code: "ABCD2345",
        },
      ]);
      const body: Record<string, string> = { idToken: "valid" };
      if (bodyNonce !== undefined) body.nonce = bodyNonce;
      return handleLogin(makeCtx({ env, jsonBody: body }));
    }

    it("accepts a matching pair", async () => {
      const res = await loginWith("n-abc", "n-abc");
      expect(res.status).toBe(200);
    });

    it("401 nonce_mismatch when the values differ", async () => {
      const res = await loginWith("n-abc", "n-xyz");
      expect(res.status).toBe(401);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("nonce_mismatch");
    });

    it("accepts a login with no nonce on either side (builds in the field)", async () => {
      const res = await loginWith(undefined);
      expect(res.status).toBe(200);
    });

    it("401 when the TOKEN carries a nonce the request omits (downgrade)", async () => {
      const res = await loginWith("n-abc");
      expect(res.status).toBe(401);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("nonce_mismatch");
    });

    it("401 when the REQUEST carries a nonce the token does not", async () => {
      const res = await loginWith(undefined, "n-abc");
      expect(res.status).toBe(401);
      expect(((await res.json()) as { error: { code: string } }).error.code).toBe("nonce_mismatch");
    });
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
    const res = await handleRefresh(makeCtx({ env, jsonBody: { refreshToken: "not.a.jwt" } }));
    expect(res.status).toBe(401);
  });

  it("rotates tokens and denylists the old jti on success", async () => {
    const env = makeEnv({ JWT_SECRET });
    const { token, jti } = await signRefreshToken(USER_ID, JWT_SECRET);

    const res = await handleRefresh(makeCtx({ env, jsonBody: { refreshToken: token } }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { accessToken: string; refreshToken: string };
    expect(typeof body.accessToken).toBe("string");

    // The old jti is now denylisted AND the new refresh token carries a fresh one -> both halves of a rotation
    expect(await isJtiDenylisted(env.KV, jti)).toBe(true);
    const newClaims = await verifyRefreshToken(body.refreshToken, JWT_SECRET);
    expect(newClaims.jti).not.toBe(jti);
  });

  it("401 when the refresh jti is already denylisted (reuse)", async () => {
    const env = makeEnv({ JWT_SECRET });
    const { token, jti } = await signRefreshToken(USER_ID, JWT_SECRET);
    await denylistJti(env.KV, jti, Math.floor(Date.now() / 1000) + 3600);

    const res = await handleRefresh(makeCtx({ env, jsonBody: { refreshToken: token } }));
    expect(res.status).toBe(401);
  });
});

// ── POST /auth/logout ──────────────────────────────────────────────────────--

describe("POST /auth/logout", () => {
  it("401 without an access token", async () => {
    const env = makeEnv({ JWT_SECRET });
    const res = await handleLogout(makeCtx({ env, jsonBody: { refreshToken: "x" } }));
    expect(res.status).toBe(401);
  });

  it("denylists the refresh token and returns ok", async () => {
    const env = makeEnv({ JWT_SECRET });
    const access = await signAccessToken(USER_ID, JWT_SECRET);
    const { token: refresh, jti } = await signRefreshToken(USER_ID, JWT_SECRET);

    const res = await handleLogout(makeCtx({ env, token: access, jsonBody: { refreshToken: refresh } }));
    expect(res.status).toBe(200);
    expect(await isJtiDenylisted(env.KV, jti)).toBe(true);
  });

  it("is idempotent: ok even when the refresh token is already invalid", async () => {
    const env = makeEnv({ JWT_SECRET });
    const access = await signAccessToken(USER_ID, JWT_SECRET);

    const res = await handleLogout(makeCtx({ env, token: access, jsonBody: { refreshToken: "garbage" } }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });
});
