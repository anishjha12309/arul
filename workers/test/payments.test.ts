/**
 * Route tests for the one-free-trial-per-user guard in payments.ts.
 *
 * Coverage:
 *   - /payments/initiate: trial-eligible user (no row / trial_end NULL) →
 *     PENNY_DROP setup (no upfrontAmountPaise), trialEligible=true.
 *     Trial-consumed user (trial_end set) → TRANSACTION setup with ₹199
 *     upfront, trialEligible=false.
 *   - /payments/initiate claim guard: a fresh 'pending' claim blocks a second
 *     setup (409, PhonePe never called); a stale abandoned claim is retryable
 *     and the superseded mandate gets revoked.
 *   - /payments/webhook checkout.order.completed: the UPDATE branches on the
 *     row's OWN trial_end (CASE … trialing/active, COALESCE keeps the original
 *     trial_end as the consumed-marker); a repeat (paid) activation triggers
 *     the referral reward, a first trial does not.
 *
 * The DB is a queue-based tagged-template mock (one result set per query, in
 * order); PhonePe's setupSubscription is mocked, verifyCallbackAuth is real.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Context } from "hono";
import type { Env } from "../src/env.js";
import { makeEnv } from "./_ctx.js";
import { signAccessToken } from "../src/lib/jwt.js";

// getDb(env) → injected mock sql on env._testSql. Keep the real toDate — it is
// pure timestamptz coercion shared with the autopay cron, and stubbing it would
// silently break every date comparison in the initiate claim guard.
vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return {
    ...actual,
    getDb: (env: { _testSql: unknown }) => env._testSql,
  };
});

// Observe paid-activation referral grants without touching a DB.
vi.mock("../src/lib/referral.js", () => ({
  grantReferralReward: vi.fn().mockResolvedValue(undefined),
}));

// Mock setupSubscription + revokeMandateTolerant (the latter so the superseded-
// mandate revoke in handleInitiate never reaches PhonePe from a test); keep the
// real ID builders + verifyCallbackAuth.
vi.mock("../src/lib/phonepe.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/phonepe.js")>();
  return {
    ...actual,
    setupSubscription: vi.fn().mockResolvedValue({
      orderId: "PP_ORDER_1",
      state: "PENDING",
      redirectUrl: "",
      token: "SDK_TOKEN",
      expireAt: 1234567890,
    }),
    revokeMandateTolerant: vi.fn().mockResolvedValue(true),
  };
});

import { handleInitiate, handleWebhook } from "../src/routes/payments.js";
import { setupSubscription, revokeMandateTolerant } from "../src/lib/phonepe.js";
import { grantReferralReward } from "../src/lib/referral.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";

/**
 * Tagged-template SQL mock that pops one result set per query, in order
 * (the last set repeats if more queries arrive). Captures the raw SQL text.
 */
function makeQueueSql(results: unknown[][]) {
  const texts: string[] = [];
  let i = 0;
  const fn = vi.fn((strings: TemplateStringsArray | string[], ..._vals: unknown[]) => {
    texts.push(Array.isArray(strings) ? strings.join("$") : String(strings));
    const res = results[Math.min(i, results.length - 1)] ?? [];
    i += 1;
    return Promise.resolve(res);
  });
  const sql = Object.assign(fn, {
    end: vi.fn().mockResolvedValue(undefined),
    // handleInitiate claims the mandate slot inside a transaction so concurrent
    // initiates serialize on the user row. The mock runs the callback against
    // the same tagged-template fn, so every statement inside still lands in
    // `texts` and still pops the result queue in order.
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(fn)),
  });
  return { sql, texts };
}

function makeInitiateCtx(env: Env, token: string): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      url: "https://api.hsrutility.com/payments/initiate",
      header: (name: string) =>
        name.toLowerCase() === "authorization" ? `Bearer ${token}` : undefined,
      json: () => Promise.resolve({ plan: "monthly" }),
    },
    json: (body: unknown, status = 200) => Response.json(body, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}

/** SHA256(username:password) hex — what PhonePe puts in Authorization. */
async function webhookAuthHeader(username: string, password: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${username}:${password}`),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function makeWebhookCtx(env: Env, authHeader: string, payload: unknown): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      header: (name: string) =>
        name.toLowerCase() === "authorization" ? authHeader : undefined,
      text: () => Promise.resolve(JSON.stringify(payload)),
    },
    json: (body: unknown, status = 200) => Response.json(body, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}

// ── /payments/initiate ────────────────────────────────────────────────────────

describe("handleInitiate — one trial per user", () => {
  beforeEach(() => {
    vi.mocked(setupSubscription).mockClear();
    vi.mocked(grantReferralReward).mockClear();
  });

  it("first-time user (no subscription row) → PENNY_DROP, trialEligible=true", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [], // SELECT trial_end → no row
      [], // claim INSERT (+ later queries repeat the last set)
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));
    expect(res.status).toBe(200);

    const setupArgs = vi.mocked(setupSubscription).mock.calls[0][1];
    expect(setupArgs.upfrontAmountPaise).toBeUndefined();

    const body = (await res.json()) as Record<string, unknown>;
    expect(body.trialEligible).toBe(true);
    expect(body.amountPaise).toBe(200);
  });

  it("row exists but trial_end is NULL (setup never completed) → still trial-eligible", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [{ trial_end: null }], // pending/expired attempt, trial never granted
      [],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));
    expect(res.status).toBe(200);

    const setupArgs = vi.mocked(setupSubscription).mock.calls[0][1];
    expect(setupArgs.upfrontAmountPaise).toBeUndefined();
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.trialEligible).toBe(true);
  });

  it("trial already consumed (trial_end set) → TRANSACTION ₹199 upfront, trialEligible=false", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [{ trial_end: "2026-01-01T00:00:00.000Z" }], // trial consumed long ago
      [],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));
    expect(res.status).toBe(200);

    const setupArgs = vi.mocked(setupSubscription).mock.calls[0][1];
    expect(setupArgs.upfrontAmountPaise).toBe(19900);

    const body = (await res.json()) as Record<string, unknown>;
    expect(body.trialEligible).toBe(false);
    expect(body.amountPaise).toBe(19900);
  });
});

// ── /payments/initiate — in-flight claim guard ───────────────────────────────

describe("handleInitiate — in-flight claim guard", () => {
  beforeEach(() => {
    vi.mocked(setupSubscription).mockClear();
    vi.mocked(revokeMandateTolerant).mockClear();
  });

  it("refuses a second setup while one is still in flight, without calling PhonePe", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [
        {
          trial_end: null,
          status: "pending",
          merchant_subscription_id: "DKS_S_INFLIGHT",
          current_period_end: null,
          // Claimed moments ago by a request still waiting on PhonePe.
          updated_at: new Date().toISOString(),
        },
      ],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    // The whole point: no second mandate is ever created, so there is nothing
    // to orphan. Reaching PhonePe at all would already be the bug.
    expect(res.status).toBe(409);
    expect(vi.mocked(setupSubscription)).not.toHaveBeenCalled();
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();

    // The CODE matters as much as the status: the app turns
    // `already_subscribed` into a SUCCESS state, so answering an in-flight
    // setup with it told a double-tapping user their purchase had gone through
    // while no mandate existed at all.
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("setup_in_progress");
  });

  it("lets a stale abandoned setup be retried once the claim window lapses", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [
        {
          trial_end: null,
          status: "pending",
          merchant_subscription_id: "DKS_S_ABANDONED",
          current_period_end: null,
          // Older than SETUP_CLAIM_WINDOW_MS — the user killed the app at the
          // PhonePe sheet and came back. They must not be locked out.
          updated_at: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
        },
      ],
      [], // claim INSERT (+ later queries repeat the last set)
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(
      expect.anything(),
      "DKS_S_ABANDONED",
    );
  });
});

// ── /payments/webhook — checkout.order.completed ─────────────────────────────

describe("handleWebhook checkout.order.completed — one trial per user", () => {
  beforeEach(() => {
    vi.mocked(grantReferralReward).mockClear();
  });

  const payload = {
    event: "checkout.order.completed",
    payload: {
      state: "COMPLETED",
      merchantId: "M",
      orderId: "PP_ORDER_W1",
      merchantOrderId: "DKS_O_X",
      merchantSubscriptionId: "DKS_S_X",
      subscriptionId: "PP_SUB_X",
      amount: 19900,
    },
  };

  it("branches trialing/active on the row's own trial_end and preserves it via COALESCE", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ user_id: USER_ID, status: "trialing" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);

    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    expect(update).toContain("CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END");
    expect(update).toContain("COALESCE(trial_end,");
    // LOAD-BEARING guard — without it the webhook/status-poll race hands out a
    // full month + referral reward off a ₹2 PENNY_DROP.
    expect(update).toContain("AND status = 'pending'");
    expect(update).toContain("RETURNING user_id, status");
  });

  it("first setup (DB grants 'trialing') → no referral reward", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ user_id: USER_ID, status: "trialing" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);
    expect(vi.mocked(grantReferralReward)).not.toHaveBeenCalled();
  });

  it("repeat setup (DB returns 'active' — ₹199 paid upfront) → referral reward granted", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ user_id: USER_ID, status: "active" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);
    expect(vi.mocked(grantReferralReward)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(grantReferralReward).mock.calls[0][1]).toBe(USER_ID);
  });
});
