/**
 * Unit tests for /me route handlers.
 *
 * Mocks the DB (postgres.js Sql) and JWT verification. No network/live DB.
 * Verifies:
 *   - 401 when no/invalid token
 *   - correct response envelope + snake_case keys matching the Flutter models
 *   - 404 when no row (GET /me, GET /me/subscription)
 *   - { items: [...] } wrapping for submissions + referrals
 *   - queries are scoped to the verified sub
 */

import { describe, it, expect, vi } from "vitest";
import {
  handleMe,
  handleUpdateProfile,
  handleMeSubscription,
  handleMeSubmissions,
  handleMeReferrals,
} from "../src/routes/me.js";
import { signAccessToken } from "../src/lib/jwt.js";

const JWT_SECRET = "test-secret-must-be-at-least-32-bytes-long!";
const USER_ID = "11111111-1111-1111-1111-111111111111";

// ── Test context builder ──────────────────────────────────────────────────────

interface MockSqlResult {
  rows: unknown[];
  capturedArgs: unknown[][];
}

function makeMockSql(rows: unknown[]): { sql: unknown; result: MockSqlResult } {
  const result: MockSqlResult = { rows, capturedArgs: [] };
  const sql = Object.assign(
    vi.fn((...args: unknown[]) => {
      result.capturedArgs.push(args);
      return Promise.resolve(rows);
    }),
    { end: vi.fn().mockResolvedValue(undefined) },
  );
  return { sql, result };
}

// Build a minimal Hono-like Context for the handler.
function makeCtx(opts: {
  token?: string;
  sql: unknown;
  jsonBody?: unknown;
  invalidJson?: boolean;
}): {
  ctx: Parameters<typeof handleMe>[0];
  jsonCalls: Array<{ body: unknown; status: number }>;
} {
  const jsonCalls: Array<{ body: unknown; status: number }> = [];

  // Patch getDb indirectly: the handlers call getDb(env), so we inject a
  // pre-built sql via env._testSql and have a vi.mock replace getDb.
  const env = {
    JWT_SECRET,
    _testSql: opts.sql,
  } as unknown as Parameters<typeof handleMe>[0]["env"];

  const ctx = {
    env,
    req: {
      header: (name: string) =>
        name.toLowerCase() === "authorization" && opts.token
          ? `Bearer ${opts.token}`
          : undefined,
      json: () =>
        opts.invalidJson
          ? Promise.reject(new Error("invalid json"))
          : Promise.resolve(opts.jsonBody),
    },
    json: (body: unknown, status = 200) => {
      jsonCalls.push({ body, status });
      return Response.json(body, { status });
    },
    executionCtx: {
      waitUntil: (_p: Promise<unknown>) => {},
    },
  } as unknown as Parameters<typeof handleMe>[0];

  return { ctx, jsonCalls };
}

// Mock getDb so handlers use our injected sql.
vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

// ── GET /me ───────────────────────────────────────────────────────────────────

describe("GET /me", () => {
  it("401 when no token", async () => {
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ sql });
    const res = await handleMe(ctx);
    expect(res.status).toBe(401);
  });

  it("returns user envelope with users.id (uuid) on success", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([
      {
        id: USER_ID,
        display_name: "Aisha",
        referral_code: "ABCD2345",
      },
    ]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMe(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: Record<string, unknown> };
    expect(body.user.id).toBe(USER_ID);
    expect(body.user.displayName).toBe("Aisha");
    expect(body.user.referralCode).toBe("ABCD2345");
  });

  it("404 when user row missing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMe(ctx);
    expect(res.status).toBe(404);
  });
});

// ── POST /me/profile ────────────────────────────────────────────────────────--

describe("POST /me/profile", () => {
  it("401 when no token", async () => {
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ sql, jsonBody: { displayName: "New Name" } });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(401);
  });

  it("400 when displayName missing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql, jsonBody: {} });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(400);
  });

  it("400 when name is blank after trim", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql, jsonBody: { displayName: "   " } });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(400);
  });

  it("400 when name exceeds 200 chars", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({
      token,
      sql,
      jsonBody: { displayName: "a".repeat(201) },
    });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(400);
  });

  it("updates name, trims it, and returns the user envelope", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, result } = makeMockSql([
      {
        id: USER_ID,
        display_name: "Aisha Khan",
        email: "aisha@example.com",
        referral_code: "ABCD2345",
      },
    ]);
    const { ctx } = makeCtx({
      token,
      sql,
      jsonBody: { displayName: "  Aisha Khan  " },
    });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: Record<string, unknown> };
    expect(body.user.displayName).toBe("Aisha Khan");
    expect(body.user.email).toBe("aisha@example.com");
    // The trimmed name and the verified sub are passed to the UPDATE.
    const updateArgs = result.capturedArgs[0];
    expect(updateArgs).toContain("Aisha Khan");
    expect(updateArgs).toContain(USER_ID);
  });

  it("404 when user row missing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql, jsonBody: { displayName: "X" } });
    const res = await handleUpdateProfile(ctx);
    expect(res.status).toBe(404);
  });
});

// ── GET /me/subscription ──────────────────────────────────────────────────────

describe("GET /me/subscription", () => {
  it("404 when no subscription row", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMeSubscription(ctx);
    expect(res.status).toBe(404);
  });

  it("returns snake_case subscription matching SubscriptionModel.fromJson", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const periodEnd = new Date("2026-12-31T00:00:00.000Z");
    const { sql } = makeMockSql([
      {
        id: "sub-1",
        user_id: USER_ID,
        status: "active",
        plan: "monthly",
        phonepe_subscription_id: "PP123",
        merchant_subscription_id: "M123",
        trial_end: null,
        current_period_end: periodEnd,
        updated_at: periodEnd,
      },
    ]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMeSubscription(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.id).toBe("sub-1");
    expect(body.user_id).toBe(USER_ID);
    expect(body.status).toBe("active");
    expect(body.plan).toBe("monthly");
    expect(body.phonepe_subscription_id).toBe("PP123");
    expect(body.merchant_subscription_id).toBe("M123");
    expect(body.trial_end).toBeNull();
    expect(body.current_period_end).toBe("2026-12-31T00:00:00.000Z");
    expect(body.updated_at).toBe("2026-12-31T00:00:00.000Z");
  });
});

// ── GET /me/submissions ───────────────────────────────────────────────────────

describe("GET /me/submissions", () => {
  it("returns { items: [] } when none", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMeSubmissions(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: unknown[] };
    expect(body.items).toEqual([]);
  });

  it("returns submissions with snake_case keys wrapped in items", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const created = new Date("2026-06-01T10:00:00.000Z");
    const { sql } = makeMockSql([
      {
        id: "sm-1",
        user_id: USER_ID,
        kind: "wallpaper",
        file_key: "user/x/submissions/1.jpg",
        title: "My Pic",
        category: null,
        status: "pending",
        rejection_reason: null,
        reviewed_by: null,
        created_at: created,
      },
    ]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMeSubmissions(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Record<string, unknown>[] };
    expect(body.items).toHaveLength(1);
    const item = body.items[0];
    expect(item.id).toBe("sm-1");
    expect(item.user_id).toBe(USER_ID);
    expect(item.kind).toBe("wallpaper");
    expect(item.file_key).toBe("user/x/submissions/1.jpg");
    expect(item.title).toBe("My Pic");
    expect(item.status).toBe("pending");
    expect(item.created_at).toBe("2026-06-01T10:00:00.000Z");
  });

  it("401 when no token", async () => {
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ sql });
    const res = await handleMeSubmissions(ctx);
    expect(res.status).toBe(401);
  });
});

// ── GET /me/referrals ─────────────────────────────────────────────────────────

describe("GET /me/referrals", () => {
  it("returns referrals with snake_case keys + numeric reward_days", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const created = new Date("2026-05-01T00:00:00.000Z");
    const { sql } = makeMockSql([
      {
        id: "rf-1",
        referrer_id: USER_ID,
        referred_user_id: "22222222-2222-2222-2222-222222222222",
        status: "subscribed",
        reward_days: 30,
        created_at: created,
      },
    ]);
    const { ctx } = makeCtx({ token, sql });
    const res = await handleMeReferrals(ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Record<string, unknown>[] };
    expect(body.items).toHaveLength(1);
    const item = body.items[0];
    expect(item.id).toBe("rf-1");
    expect(item.referrer_id).toBe(USER_ID);
    expect(item.referred_user_id).toBe("22222222-2222-2222-2222-222222222222");
    expect(item.status).toBe("subscribed");
    expect(item.reward_days).toBe(30);
    expect(typeof item.reward_days).toBe("number");
    expect(item.created_at).toBe("2026-05-01T00:00:00.000Z");
  });

  it("401 when invalid token", async () => {
    const { sql } = makeMockSql([]);
    const { ctx } = makeCtx({ token: "not.a.jwt", sql });
    const res = await handleMeReferrals(ctx);
    expect(res.status).toBe(401);
  });
});
