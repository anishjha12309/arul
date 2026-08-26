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

const posthog = vi.hoisted(() => ({
  reportPostHogFirstConversion: vi.fn().mockResolvedValue(undefined),
  reportPostHogSubscriptionCancel: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("../src/lib/posthog.js", () => posthog);

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
    // handleAbandon asks PhonePe for the order's live state before expiring a
    // claim; default to a not-completed order, overridden per test.
    getOrderStatus: vi.fn().mockResolvedValue({ state: "PENDING", orderId: "PP_ORDER_1" }),
    // Direct UPI-intent setup (subscriptions/v2/setup).
    setupSubscriptionIntent: vi.fn().mockResolvedValue({
      orderId: "PP_ORDER_INT_1",
      state: "PENDING",
      intentUrl: "upi://mandate?pa=TEST@ybl&tr=OM123",
    }),
  };
});

import {
  handleInitiate,
  handleWebhook,
  handleAbandon,
  handleStatus,
  handleCancel,
} from "../src/routes/payments.js";
import {
  setupSubscription,
  setupSubscriptionIntent,
  revokeMandateTolerant,
  getOrderStatus,
} from "../src/lib/phonepe.js";
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

function makeInitiateCtx(
  env: Env,
  token: string,
  body: Record<string, unknown> = { plan: "monthly" },
): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      url: "https://api.hsrutility.com/payments/initiate",
      header: (name: string) =>
        name.toLowerCase() === "authorization" ? `Bearer ${token}` : undefined,
      json: () => Promise.resolve(body),
    },
    json: (body2: unknown, status = 200) => Response.json(body2, { status }),
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

// ── /payments/initiate — direct UPI-intent flow ──────────────────────────────

describe("handleInitiate — direct UPI-intent flow", () => {
  beforeEach(() => {
    vi.mocked(setupSubscription).mockClear();
    vi.mocked(setupSubscriptionIntent).mockClear();
  });

  it("targetApp → subscriptions/v2/setup, returns intentUrl, never touches the SDK order path", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [], // no prior subscription row → trial-eligible
      [], // claim INSERT
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(
      makeInitiateCtx(env, token, { plan: "monthly", targetApp: "com.phonepe.app" }),
    );

    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.flow).toBe("intent");
    expect(body.intentUrl).toContain("upi://mandate");
    expect(body.trialEligible).toBe(true);

    const intentArgs = vi.mocked(setupSubscriptionIntent).mock.calls[0][1];
    expect(intentArgs.targetApp).toBe("com.phonepe.app");
    expect(intentArgs.upfrontAmountPaise).toBeUndefined();
    expect(vi.mocked(setupSubscription)).not.toHaveBeenCalled();
  });

  it("falls back to the SDK page on intent-setup failure, reusing the same claimed ids", async () => {
    const env = makeEnv();
    vi.mocked(setupSubscriptionIntent).mockRejectedValueOnce(
      new Error("intent setup down"),
    );
    const { sql } = makeQueueSql([
      [], // SELECT 1 FROM users … FOR UPDATE
      [], // no prior subscription row
      [], // claim INSERT
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(
      makeInitiateCtx(env, token, { plan: "monthly", targetApp: "com.phonepe.app" }),
    );

    // A second initiate would bounce off the claim window, so the fallback MUST
    // happen inside this same request.
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.token).toBe("SDK_TOKEN");
    expect(body.intentUrl).toBeUndefined();
    const sdkArgs = vi.mocked(setupSubscription).mock.calls[0][1];
    expect(sdkArgs.merchantOrderId).toBe(body.merchantOrderId);
  });

  it("ignores a malformed targetApp and uses the SDK path directly", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([[], [], []]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(
      makeInitiateCtx(env, token, { plan: "monthly", targetApp: "upi://evil not-a-package!!" }),
    );

    expect(res.status).toBe(200);
    expect(vi.mocked(setupSubscriptionIntent)).not.toHaveBeenCalled();
    expect(vi.mocked(setupSubscription)).toHaveBeenCalled();
  });
});

// ── /payments/webhook — intent-flow setup event alias ────────────────────────

describe("handleWebhook — subscription.setup.order.completed (intent flow)", () => {
  it("routes the intent-flow setup event to the same grant as checkout.order.completed", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ user_id: USER_ID, status: "trialing" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.setup.order.completed",
        payload: {
          state: "COMPLETED",
          merchantId: "M",
          orderId: "PP_ORDER_INT_W1",
          merchantOrderId: "DKS_O_INT",
          merchantSubscriptionId: "DKS_S_INT",
          subscriptionId: "PP_SUB_INT",
          amount: 200,
        },
      }),
    );

    expect(res.status).toBe(200);
    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    expect(update).toContain("AND status = 'pending'");
    expect(update).toContain("CASE WHEN trial_end IS NULL THEN 'trialing' ELSE 'active' END");
  });
});

// ── /payments/webhook — abandon-raced approval resurrect ─────────────────────

describe("handleWebhook — approval racing an auto-cancelled claim", () => {
  it("resurrects an abandon-expired row scoped to this event's exact ids", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [], // UPDATE scoped AND status='pending' → no row (abandon already expired it)
      [{ user_id: USER_ID, status: "active" }], // resurrect UPDATE
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.setup.order.completed",
        payload: {
          state: "COMPLETED",
          merchantId: "M",
          orderId: "PP_ORDER_RACE",
          merchantOrderId: "DKS_O_RACE",
          merchantSubscriptionId: "DKS_S_RACE",
          subscriptionId: "PP_SUB_RACE",
          amount: 19900,
        },
      }),
    );

    // The user PAID — the grant must land even though the app already said
    // "failed". Resurrection is scoped to the exact ids + the two post-abandon
    // statuses: 'expired', and 'cancelled' since the restore rule (a released
    // claim over a still-paid period goes back to 'cancelled'). The exact-id
    // scope is what keeps a dunning-expired or genuinely-cancelled OLD
    // subscription from riding in on it.
    expect(res.status).toBe(200);
    const resurrect = texts.find((t) =>
      t.includes("AND status IN ('expired', 'cancelled')"),
    );
    expect(resurrect).toBeDefined();
    expect(resurrect).toContain("merchant_order_id");
    // active resurrect = a real ₹199 debit → referral applies like any paid setup.
    expect(vi.mocked(grantReferralReward)).toHaveBeenCalled();
  });
});

// ── /payments/status — FAILED-setup reconcile ────────────────────────────────

describe("handleWebhook — subscription.unpaused rearms the debit clock", () => {
  it("restores status AND next_debit_at, scoped to paused rows only", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.unpaused",
        payload: {
          merchantSubscriptionId: "DKS_S_UNPAUSE",
          orderId: "PP_ORDER_UNPAUSE",
        },
      }),
    );
    expect(res.status).toBe(200);

    // The cron's park nulls next_debit_at, so a status-only restore left a row
    // the billing passes could never select again — "Active" forever, never
    // billed, premium silently dead at period end. The rearm is the fix; the
    // paused-only scope is what stops a stray unpaused event resurrecting a
    // cancelled/expired row.
    const unpause = texts.find((t) => t.includes("'trialing' ELSE 'active'"));
    expect(unpause).toBeDefined();
    expect(unpause).toContain("COALESCE(next_debit_at, current_period_end)");
    expect(unpause).toContain("AND status = 'paused'");
  });
});

describe("handleStatus — FAILED setup reconcile", () => {
  it("flips a pending row to 'expired' when PhonePe reports the order FAILED", async () => {
    const env = makeEnv();
    vi.mocked(getOrderStatus).mockResolvedValueOnce({
      state: "FAILED",
      orderId: "PP_ORDER_1",
    } as never);
    const { sql, texts } = makeQueueSql([
      [
        {
          id: "sub-row-1",
          user_id: USER_ID,
          status: "pending",
          plan: "monthly",
          merchant_subscription_id: null,
          merchant_order_id: "DKS_O_CANCELLED",
          phonepe_order_id: "PP_ORDER_1",
          phonepe_subscription_id: null,
          current_period_end: null,
          trial_end: null,
          next_debit_at: null,
          notified_at: null,
          retry_count: 0,
          updated_at: new Date().toISOString(),
        },
      ],
      [], // UPDATE → expired
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleStatus(makeAbandonCtx(env, token, "ignored"));

    // The intent flow has no SDK callback: an in-app cancel at PhonePe leaves
    // the row 'pending' forever unless this reconcile flips it — the app's
    // poll then spun its whole budget on a row nothing would ever change.
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string };
    expect(body.status).toBe("expired");
    const update = texts.find((t) => t.includes("'expired'"));
    expect(update).toBeDefined();
    expect(update).toContain("AND status  = 'pending'");
  });
});

// ── /payments/abandon — releasing a claimed setup ────────────────────────────

function makeAbandonCtx(env: Env, token: string, merchantOrderId: string): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      url: "https://api.hsrutility.com/payments/abandon",
      header: (name: string) =>
        name.toLowerCase() === "authorization" ? `Bearer ${token}` : undefined,
      json: () => Promise.resolve({ merchantOrderId }),
    },
    json: (body: unknown, status = 200) => Response.json(body, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}

describe("handleAbandon — releasing a claimed setup", () => {
  beforeEach(() => {
    vi.mocked(getOrderStatus).mockClear();
    vi.mocked(revokeMandateTolerant).mockClear();
  });

  it("expires the pending claim and revokes the dead mandate", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ status: "pending", merchant_subscription_id: "DKS_S_DEAD" }],
      [{ id: "sub-dead" }], // UPDATE → expired, RETURNING the row it released
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_DEAD"));

    expect(res.status).toBe(200);
    const body = (await res.json()) as { abandoned: boolean; settled: boolean };
    expect(body.abandoned).toBe(true);
    expect(body.settled).toBe(false);

    // Scoped expire: only the caller's own still-pending row for THIS order —
    // a late abandon must never kill a newer claim that superseded it.
    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    expect(update).toContain("'expired'");
    expect(update).toContain("AND status = 'pending'");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(
      expect.anything(),
      "DKS_S_DEAD",
    );
  });

  it("does NOT revoke when the grant landed between the read and the expire", async () => {
    // The race that locked three live subscriptions out of premium on
    // 2026-08-11: the row reads 'pending' and PhonePe still says PENDING, so
    // abandon proceeds — but the grant lands before its UPDATE, which then
    // matches zero rows. The read-time guards cannot catch this by
    // construction; only the UPDATE's own result can. Revoking here would tear
    // down a mandate that is now live and paid for.
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ status: "pending", merchant_subscription_id: "DKS_S_RACED" }],
      [], // UPDATE matched nothing — no longer 'pending'
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_RACED"));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();
  });

  it("refuses to expire a setup PhonePe reports COMPLETED and reports settled", async () => {
    const env = makeEnv();
    vi.mocked(getOrderStatus).mockResolvedValueOnce({
      state: "COMPLETED",
      orderId: "PP_ORDER_1",
    } as never);
    const { sql, texts } = makeQueueSql([
      [{ status: "pending", merchant_subscription_id: "DKS_S_PAID" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_PAID"));

    // The one case where "the SDK said cancel" is a lie: the mandate settled.
    // Expiring here would strand a paid mandate — the app must poll instead.
    const body = (await res.json()) as { abandoned: boolean; settled: boolean };
    expect(body.abandoned).toBe(false);
    expect(body.settled).toBe(true);
    expect(texts.some((t) => t.includes("'expired'"))).toBe(false);
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();
  });

  it("no-ops when the claim was already superseded by a newer initiate", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [], // no row matches user + merchant_order_id
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_STALE"));

    const body = (await res.json()) as { abandoned: boolean; settled: boolean };
    expect(body.abandoned).toBe(false);
    expect(body.settled).toBe(false);
    expect(vi.mocked(getOrderStatus)).not.toHaveBeenCalled();
    expect(texts.some((t) => t.includes("'expired'"))).toBe(false);
  });
});

// ── /payments/webhook — checkout.order.completed ─────────────────────────────

describe("handleWebhook — PhonePe's DOCUMENTED order-event shape (ids under paymentFlow)", () => {
  // PhonePe webhook-handling reference (read 2026-08-25): for every ORDER event
  // merchantSubscriptionId + subscriptionId live under payload.paymentFlow, NOT
  // at the top of payload. The flat fixtures elsewhere in this file are the
  // state-change shape; reading only that shape acked every real redemption
  // webhook with "Missing merchantSubscriptionId" (0 txn:* marks in prod).
  it("grants the month from a redemption.order.completed with ids nested under paymentFlow", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ user_id: USER_ID, status: "trialing" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        type: "SUBSCRIPTION_REDEMPTION_ORDER_COMPLETED",
        event: "subscription.redemption.order.completed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_R_NEST_1",
          orderId: "OMO_NEST_1",
          state: "COMPLETED",
          amount: 19900,
          paymentFlow: {
            type: "SUBSCRIPTION_REDEMPTION",
            merchantSubscriptionId: "DKS_S_NEST",
            subscriptionId: "OMS_NEST",
            amountType: "FIXED",
            maxAmount: 19900,
            frequency: "MONTHLY",
          },
        },
      }),
    );

    expect(res.status).toBe(200);
    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    expect(env.KV.put).toHaveBeenCalledWith(
      "txn:subscription.redemption.order.completed:OMO_NEST_1",
      "1",
      expect.anything(),
    );
  });

  it("grants the trial from a setup.order.completed with ids nested under paymentFlow", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ user_id: USER_ID, status: "trialing" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.setup.order.completed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_O_NEST",
          orderId: "OMO_NEST_2",
          state: "COMPLETED",
          amount: 200,
          paymentFlow: {
            type: "SUBSCRIPTION_CHECKOUT_SETUP",
            merchantSubscriptionId: "DKS_S_NEST2",
            subscriptionId: "OMS_NEST2",
            authWorkflowType: "PENNY_DROP",
          },
        },
      }),
    );

    expect(res.status).toBe(200);
    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    // PhonePe's own id must be captured from the nested home too.
    expect(update).toContain("phonepe_subscription_id");
  });
});

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

// ── The RESTORE rule — every path that releases a claim ──────────────────────
//
// A resubscribe rides over the user's ONE subscriptions row, so at claim time a
// still-paid row — a live trial, or days already bought — becomes 'pending'.
// Writing a flat status='expired' when that claim is released STRIPS
// entitlement the user still owns. It stripped three live trials in production
// on 2026-08-11/12 (trial cancelled → Resubscribe → backed out at the UPI app),
// each losing 10–16 h of a 24 h trial, before the CASE below landed.
//
// THREE surfaces release a claim and they must agree, because a user reaches
// them by route rather than by choice: the failed-setup webhook (SDK/hosted
// page), the /payments/status reconcile (direct UPI-intent, which has no SDK
// callback at all), and /payments/abandon. A rule that holds on two of them is
// the same outage for whoever hits the third.
//
// These assert the CONDITIONAL, not merely that 'expired' appears somewhere:
// the pre-existing assertions matched `'expired'` as a substring, which both
// the flat write and the CASE satisfy, so they passed throughout the incident
// and could never have caught it. The negative assertion is the load-bearing
// one — it is what fails if anyone reverts to an unconditional expire.
function expectRestoreRule(update: string | undefined, path: string): void {
  expect(update, `${path}: no release UPDATE was captured`).toBeDefined();
  const sql = (update as string).replace(/\s+/g, " ");
  expect(sql, `${path}: must gate on a live period`).toContain(
    "CASE WHEN current_period_end IS NOT NULL AND current_period_end > now()",
  );
  expect(sql, `${path}: a live period must restore, not expire`).toContain(
    "THEN 'cancelled' ELSE 'expired' END",
  );
  expect(sql, `${path}: unconditional expire strips a paid period`).not.toMatch(
    /SET\s+status\s*=\s*'expired'/,
  );
}

describe("the RESTORE rule holds on all three release paths", () => {
  beforeEach(() => {
    vi.mocked(getOrderStatus).mockClear();
    vi.mocked(revokeMandateTolerant).mockClear();
  });

  it("failed-setup webhook restores a still-paid row instead of expiring it", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "checkout.order.failed",
        payload: {
          state: "FAILED",
          merchantId: "M",
          orderId: "PP_ORDER_FAILED",
          merchantOrderId: "DKS_O_FAILED",
          merchantSubscriptionId: "DKS_S_FAILED",
        },
      }),
    );

    expect(res.status).toBe(200);
    expectRestoreRule(
      texts.find((t) => t.includes("UPDATE subscriptions")),
      "checkout.order.failed",
    );
  });

  it("status reconcile restores a still-paid row when PhonePe reports FAILED", async () => {
    const env = makeEnv();
    vi.mocked(getOrderStatus).mockResolvedValueOnce({
      state: "FAILED",
      orderId: "PP_ORDER_1",
    } as never);
    // A resubscribe mid-trial: the claim is 'pending' but current_period_end is
    // still ahead, which is precisely the row the incident expired.
    const { sql, texts } = makeQueueSql([
      [
        {
          id: "sub-row-live",
          user_id: USER_ID,
          status: "pending",
          plan: "monthly",
          merchant_subscription_id: null,
          merchant_order_id: "DKS_O_LIVE",
          phonepe_order_id: "PP_ORDER_1",
          phonepe_subscription_id: null,
          current_period_end: new Date(Date.now() + 86_400_000).toISOString(),
          trial_end: new Date(Date.now() + 86_400_000).toISOString(),
          next_debit_at: null,
          notified_at: null,
          retry_count: 0,
          updated_at: new Date().toISOString(),
        },
      ],
      [{ status: "cancelled" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleStatus(makeAbandonCtx(env, token, "ignored"));

    expect(res.status).toBe(200);
    // The response must report what the DB decided, not a hardcoded guess —
    // the app paywalls straight off this field.
    const body = (await res.json()) as { status: string };
    expect(body.status).toBe("cancelled");
    expectRestoreRule(
      texts.find((t) => t.includes("UPDATE subscriptions")),
      "handleStatus reconcile",
    );
  });

  it("abandon restores a still-paid row when the user backs out", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ status: "pending", merchant_subscription_id: "DKS_S_LIVE" }],
      [{ id: "sub-live" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_LIVE"));

    expect(res.status).toBe(200);
    expectRestoreRule(
      texts.find((t) => t.includes("UPDATE subscriptions")),
      "handleAbandon",
    );
  });
});

describe("handleCancel — subscription_cancel reporting", () => {
  beforeEach(() => {
    posthog.reportPostHogSubscriptionCancel.mockClear();
  });

  it("reports user_cancel with the row's PRIOR status after revoking at PhonePe", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ merchant_subscription_id: "DKS_S_CANCEL", status: "trialing" }],
      [], // UPDATE → cancelled
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(env, "DKS_S_CANCEL");
    expect(texts.find((t) => t.includes("'cancelled'"))).toBeDefined();
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledTimes(1);
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledWith(env, {
      userId: USER_ID,
      merchantSubId: "DKS_S_CANCEL",
      reason: "user_cancel",
      priorStatus: "trialing",
    });
  });

  it("does not report when the row was already cancelled (no state change)", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ merchant_subscription_id: "DKS_S_DONE", status: "cancelled" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });

  it("does not report when PhonePe refused the revoke (nothing was cancelled)", async () => {
    vi.mocked(revokeMandateTolerant).mockResolvedValueOnce(false);
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ merchant_subscription_id: "DKS_S_REFUSED", status: "active" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(502);
    expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });
});
