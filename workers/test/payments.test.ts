/**
 * The DB is a QUEUE-based mock -> one result set per query, in order -> a reordered statement changes what a test sees
 * setupSubscription is mocked; verifyCallbackAuth runs for real
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Context } from "hono";
import type { Env } from "../src/env.js";
import { makeEnv } from "./_ctx.js";
import { signAccessToken } from "../src/lib/jwt.js";

// getDb(env) is replaced -> handlers reach the injected mock sql through env._testSql
// Keep the REAL toDate -> it is pure timestamptz coercion shared with the cron
// Stubbing it would silently break every date comparison in the initiate claim guard
vi.mock("../src/lib/db.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/lib/db.js")>();
  return {
    ...actual,
    getDb: (env: { _testSql: unknown }) => env._testSql,
  };
});

// Observe paid-activation referral grants without touching a DB
vi.mock("../src/lib/referral.js", () => ({
  grantReferralReward: vi.fn().mockResolvedValue(undefined),
}));

const posthog = vi.hoisted(() => ({
  reportPostHogFirstConversion: vi.fn().mockResolvedValue(undefined),
  reportPostHogSubscriptionCancel: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("../src/lib/posthog.js", () => posthog);

// Mock setupSubscription and revokeMandateTolerant -> the supersede revoke must never reach PhonePe from a test
// Keep the REAL id builders and verifyCallbackAuth -> both are contracts these tests are meant to pin
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
    getSubscriptionStatus: vi.fn().mockResolvedValue({ state: "ACTIVE" }),
    // handleAbandon asks PhonePe for the order's live state before expiring a claim -> default to not-completed
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
import { reportPostHogFirstConversion } from "../src/lib/posthog.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";

/**
 * Pops one result set per EXECUTED query, in order; the LAST set repeats if more queries arrive. Lazy like postgres.js:
 * a query runs only when awaited, so a fragment interpolated into another is never executed — its text is inlined
 * into the parent's captured SQL instead
 */
function makeQueueSql(results: unknown[][]) {
  const texts: string[] = [];
  const executed: { text: string; values: unknown[] }[] = [];
  let i = 0;
  const fn = vi.fn((strings: TemplateStringsArray | string[], ...vals: unknown[]) => {
    const text = Array.isArray(strings)
      ? strings.reduce((acc, part, k) => {
          const v = vals[k - 1] as { sqlText?: string } | undefined;
          return acc + (typeof v?.sqlText === "string" ? v.sqlText : "$") + part;
        })
      : String(strings);
    const values = vals.flatMap((v) => ((v as { sqlValues?: unknown[] })?.sqlValues ?? [v]) as unknown[]);
    let run: Promise<unknown> | null = null;
    const exec = () => {
      if (!run) {
        texts.push(text);
        executed.push({ text, values });
        run = Promise.resolve(results[Math.min(i, results.length - 1)] ?? []);
        i += 1;
      }
      return run;
    };
    return {
      sqlText: text,
      sqlValues: values,
      // biome-ignore lint/suspicious/noThenProperty: postgres.js queries are lazy thenables; the mock must be one too
      then: (ok?: (v: unknown) => unknown, bad?: (e: unknown) => unknown) => exec().then(ok, bad),
      catch: (bad: (e: unknown) => unknown) => exec().catch(bad),
    };
  });
  const sql = Object.assign(fn, {
    end: vi.fn().mockResolvedValue(undefined),
    // handleInitiate claims the mandate slot inside a TRANSACTION -> concurrent initiates serialize on the user row
    // The mock runs that callback against the same tagged-template fn -> statements inside still land in `texts`
    begin: vi.fn(async (cb: (tx: unknown) => Promise<unknown>) => cb(fn)),
  });
  return { sql, texts, executed };
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
      header: (name: string) => (name.toLowerCase() === "authorization" ? `Bearer ${token}` : undefined),
      json: () => Promise.resolve(body),
    },
    json: (body2: unknown, status = 200) => Response.json(body2, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}

/** SHA256(username:password) hex -> exactly what PhonePe puts in Authorization, with no scheme prefix. */
async function webhookAuthHeader(username: string, password: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${username}:${password}`));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function makeWebhookCtx(env: Env, authHeader: string, payload: unknown): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      header: (name: string) => (name.toLowerCase() === "authorization" ? authHeader : undefined),
      text: () => Promise.resolve(JSON.stringify(payload)),
    },
    json: (body: unknown, status = 200) => Response.json(body, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}

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
      [{ trial_end: "2026-01-01T00:00:00.000Z" }], // unlocked pre-read
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

describe("handleInitiate — in-flight claim guard", () => {
  beforeEach(() => {
    vi.mocked(setupSubscription).mockClear();
    vi.mocked(revokeMandateTolerant).mockClear();
  });

  it("refuses a second setup while one is still in flight, without calling PhonePe", async () => {
    const env = makeEnv();
    const inflight = {
      trial_end: null,
      status: "pending",
      merchant_subscription_id: "DKS_S_INFLIGHT",
      current_period_end: null,
      // Claimed moments ago by a request still waiting on PhonePe -> inside SETUP_CLAIM_WINDOW_MS
      updated_at: new Date().toISOString(),
    };
    const { sql } = makeQueueSql([
      [inflight], // unlocked pre-read
      [], // SELECT 1 FROM users … FOR UPDATE
      [inflight],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    // The whole point -> no second mandate is created, so there is nothing to orphan
    // Reaching PhonePe at all would already be the bug -> assert the call count, not just the response
    expect(res.status).toBe(409);
    expect(vi.mocked(setupSubscription)).not.toHaveBeenCalled();
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();

    // The CODE matters as much as the status -> the app turns `already_subscribed` into a SUCCESS state
    // Answering an in-flight setup with it told a double-tapping user their purchase went through
    // No mandate existed at all -> the two refusal reasons must stay distinguishable out to the client
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("setup_in_progress");
  });

  it("an offer double tap is refused as setup_in_progress, never offer_unavailable", async () => {
    // The app retries setup_in_progress silently; offer_unavailable would tell a double-tapper the offer is gone
    vi.mocked(setupSubscriptionIntent).mockClear();
    const env = makeEnv();
    const claimed = {
      trial_end: new Date(Date.now() - 86_400_000).toISOString(),
      status: "pending",
      offer_switch: true,
      merchant_subscription_id: "DKS_HS_FIRST99",
      superseded_mandate_id: "DKS_S_OLD199",
      current_period_end: new Date(Date.now() + 86_400_000).toISOString(),
      updated_at: new Date().toISOString(),
      offer_eligible: false,
    };
    const { sql } = makeQueueSql([[claimed]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(
      makeInitiateCtx(env, token, { plan: "monthly", offer: "cancel_99", targetApp: "com.phonepe.app" }),
    );

    expect(res.status).toBe(409);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("setup_in_progress");
    expect(vi.mocked(setupSubscriptionIntent)).not.toHaveBeenCalled();
    expect(vi.mocked(setupSubscription)).not.toHaveBeenCalled();
  });

  it("lets a stale abandoned setup be retried once the claim window lapses", async () => {
    const env = makeEnv();
    const abandoned = {
      trial_end: null,
      status: "pending",
      merchant_subscription_id: "DKS_S_ABANDONED",
      current_period_end: null,
      // Older than SETUP_CLAIM_WINDOW_MS -> the user killed the app at the PhonePe sheet and came back
      // They must not be locked out -> a claim nobody can release is worse than a second attempt
      updated_at: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
    };
    const { sql } = makeQueueSql([
      [abandoned], // unlocked pre-read
      [], // SELECT 1 FROM users … FOR UPDATE
      [abandoned],
      [], // claim INSERT (+ later queries repeat the last set)
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_ABANDONED");
  });
});

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

    // The row remembers which UPI app took the mandate -> read back at the first paid settle
    const sqlCalls = (sql as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(sqlCalls.some((call) => call.slice(1).includes("com.phonepe.app"))).toBe(true);
    expect(sqlCalls.some((call) => call.slice(1).includes("phonepe_page"))).toBe(false);
  });

  it("falls back to the SDK page on intent-setup failure, reusing the same claimed ids", async () => {
    const env = makeEnv();
    vi.mocked(setupSubscriptionIntent).mockRejectedValueOnce(new Error("intent setup down"));
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

    // A second initiate would bounce off the claim window -> the fallback MUST happen inside this same request
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.token).toBe("SDK_TOKEN");
    expect(body.intentUrl).toBeUndefined();
    const sdkArgs = vi.mocked(setupSubscription).mock.calls[0][1];
    expect(sdkArgs.merchantOrderId).toBe(body.merchantOrderId);

    // The row must name the flow that RAN, not the one that was asked for -> the fallback re-stamps it
    const sqlCalls = (sql as unknown as { mock: { calls: unknown[][] } }).mock.calls;
    expect(sqlCalls.some((call) => call.slice(1).includes("phonepe_page"))).toBe(true);
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

describe("handleWebhook — subscription.setup.order.completed (intent flow)", () => {
  it("routes the intent-flow setup event to the same grant as checkout.order.completed", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[], [{ user_id: USER_ID, status: "trialing" }]]);
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
    // The switch runs first on every grant surface -> it must be scoped to offer rows only
    expect(texts[0]).toContain("AND s.offer_switch");
    const update = texts.find((t) => t.includes("AND NOT s.offer_switch"));
    expect(update).toBeDefined();
    expect(update).toContain("AND s.status = 'pending'");
    expect(update).toContain("CASE WHEN s.trial_end IS NULL THEN 'trialing' ELSE 'active' END");
  });
});

describe("handleWebhook — approval racing an auto-cancelled claim", () => {
  it("resurrects an abandon-expired row scoped to this event's exact ids", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [], // the offer switch → not an offer row
      [], // UPDATE scoped AND status='pending' → no row (abandon already expired it)
      [], // no row watches this id as a released ₹99
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

    // The user PAID -> the grant must land even though the app already said "failed"
    // Resurrection is scoped to the EXACT ids plus the two post-abandon statuses -> 'expired' and 'cancelled'
    // 'cancelled' is in the list because of the restore rule -> a released claim over a still-paid period lands there
    // The exact-id scope is what keeps a dunning-expired or genuinely-cancelled OLD subscription from riding in
    expect(res.status).toBe(200);
    const resurrect = texts.find((t) => t.includes("AND s.status IN ('expired', 'cancelled')"));
    expect(resurrect).toBeDefined();
    expect(resurrect).toContain("merchant_order_id");
    // A cancel_99 row is never resurrected -> a ₹2 check is not a paid month
    expect(resurrect).toContain("AND NOT s.offer_switch");
    // An 'active' resurrect means a real ₹199 debit -> the referral reward applies exactly as on any paid setup
    expect(vi.mocked(grantReferralReward)).toHaveBeenCalled();
  });
});

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

    // The cron's park NULLs next_debit_at -> a status-only restore leaves a row neither pass can select again
    // That row reads "Active" forever, is never billed, and its premium dies silently at period end
    // The rearm is the fix -> and the paused-only scope stops a stray unpause resurrecting a cancelled row
    const unpause = texts.find((t) => t.includes("COALESCE(next_debit_at, current_period_end)"));
    expect(unpause).toBeDefined();
    // Converted = the period ran past the trial -> an unpaused never-converted trial stays 'trialing'
    expect(unpause).toContain("WHEN trial_end IS NOT NULL AND current_period_end > trial_end");
    expect(unpause).toContain("THEN 'active' ELSE 'trialing'");
    expect(unpause).toContain("AND status = 'paused'");
  });
});

describe("handleWebhook — state events in PhonePe's DOCUMENTED shape (no order id)", () => {
  // developer.phonepe.com -> Autopay -> Webhook -> "Response for State Change": ids and pause dates only
  const stateEvent = (event: string, state: string, pauseStartDate: number | null = null) => ({
    event,
    payload: {
      merchantSubscriptionId: "DKS_S_STATE",
      subscriptionId: "OMS_STATE",
      state,
      authWorkflowType: "PENNY_DROP",
      amountType: "FIXED",
      maxAmount: 19900,
      frequency: "MONTHLY",
      expireAt: 1737278524000,
      pauseStartDate,
      pauseEndDate: pauseStartDate === null ? null : pauseStartDate + 86_400_000,
    },
  });

  async function deliver(env: Env, body: unknown) {
    const auth = await webhookAuthHeader("u", "p");
    return handleWebhook(makeWebhookCtx(env, auth, body));
  }

  beforeEach(() => {
    posthog.reportPostHogSubscriptionCancel.mockClear();
  });

  // The shared park binds its status -> a pause is the park statement carrying 'paused'
  const pauseParks = (executed: { text: string; values: unknown[] }[]) =>
    executed.filter((q) => q.text.includes("next_debit_at = NULL") && q.values.includes("paused"));

  it("parks the row paused on subscription.paused", async () => {
    const env = makeEnv();
    const { sql, executed } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_790_000_000_000));

    expect(res.status).toBe(200);
    const park = pauseParks(executed)[0];
    expect(park).toBeDefined();
    // The same write as the cron's park -> a status-only pause kept a debit clock no pass would serve
    expect(park.text).toContain("notified_at   = NULL");
    expect(park.text).toContain("s.status IN ('trialing', 'active')");
  });

  it.each([
    ["subscription.revoked", "REVOKED"],
    ["subscription.cancelled", "CANCELLED"],
  ])("cancels the row on %s and reports the churn", async (event, state) => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[], [{ user_id: USER_ID, prior_status: "trialing" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await deliver(env, stateEvent(event, state));

    expect(res.status).toBe(200);
    expect(texts.some((t) => t.includes("SET status        = 'cancelled'"))).toBe(true);
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledWith(
      env,
      expect.objectContaining({ merchantSubId: "DKS_S_STATE", reason: "webhook_revoked" }),
    );
  });

  it("rearms the row on subscription.unpaused", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await deliver(env, stateEvent("subscription.unpaused", "ACTIVE"));

    expect(res.status).toBe(200);
    expect(texts.some((t) => t.includes("COALESCE(next_debit_at, current_period_end)"))).toBe(true);
  });

  it("drops a redelivered pause but handles a later, different pause", async () => {
    const env = makeEnv();
    const { sql, executed } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const pauses = () => pauseParks(executed).length;

    await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_790_000_000_000));
    await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_790_000_000_000));
    expect(pauses()).toBe(1);

    await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_795_000_000_000));
    expect(pauses()).toBe(2);
  });

  it("handles the second unpause of a pause -> unpause -> pause -> unpause cycle", async () => {
    // An unpause carries null pause dates -> a key built from them alone drops every unpause after the first
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    const rearms = () =>
      texts.filter((t) => t.includes("COALESCE(next_debit_at, current_period_end)")).length;

    await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_790_000_000_000));
    await deliver(env, stateEvent("subscription.unpaused", "ACTIVE"));
    await deliver(env, stateEvent("subscription.paused", "PAUSED", 1_795_000_000_000));
    await deliver(env, stateEvent("subscription.unpaused", "ACTIVE"));

    expect(rearms()).toBe(2);
  });

  it("drops a redelivered revoke", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[], [{ user_id: USER_ID, prior_status: "trialing" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    await deliver(env, stateEvent("subscription.revoked", "REVOKED"));
    await deliver(env, stateEvent("subscription.revoked", "REVOKED"));

    expect(texts.filter((t) => t.includes("SET status        = 'cancelled'")).length).toBe(1);
  });

  it("still acks an ORDER event with no order id without processing it", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const res = await deliver(env, {
      event: "subscription.setup.order.completed",
      payload: { state: "COMPLETED", paymentFlow: { merchantSubscriptionId: "DKS_S_NOORDER" } },
    });

    expect(res.status).toBe(200);
    expect(texts.length).toBe(0);
    expect(env.KV.put).not.toHaveBeenCalled();
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

    // The intent flow has NO SDK callback -> an in-app cancel leaves the row 'pending' unless this reconcile flips it
    // The app's poll then spun its whole budget on a row nothing would ever change
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string };
    expect(body.status).toBe("expired");
    const update = texts.find((t) => t.includes("'expired'"));
    expect(update).toBeDefined();
    expect(update).toContain("AND s.status = 'pending'");
  });
});

function makeAbandonCtx(env: Env, token: string, merchantOrderId: string): Context<{ Bindings: Env }> {
  return {
    env,
    req: {
      url: "https://api.hsrutility.com/payments/abandon",
      header: (name: string) => (name.toLowerCase() === "authorization" ? `Bearer ${token}` : undefined),
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
      [{ status: "expired", released_mandate_id: "DKS_S_DEAD" }], // the release, RETURNING the id it let go
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_DEAD"));

    expect(res.status).toBe(200);
    const body = (await res.json()) as { abandoned: boolean; settled: boolean };
    expect(body.abandoned).toBe(true);
    expect(body.settled).toBe(false);

    // A SCOPED expire -> only the caller's own still-pending row for THIS order
    // A late abandon must never kill a newer claim that superseded it
    const update = texts.find((t) => t.includes("UPDATE subscriptions"));
    expect(update).toBeDefined();
    expect(update).toContain("'expired'");
    expect(update).toContain("s.user_id = $ AND s.merchant_order_id = $");
    expect(update).toContain("AND s.status = 'pending'");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_DEAD");
  });

  it("does NOT revoke when the grant landed between the read and the expire", async () => {
    // The race that locked three live subscriptions out of premium: the row reads 'pending' and PhonePe says PENDING
    // Abandon proceeds, but the grant lands before its UPDATE -> that UPDATE then matches ZERO rows
    // The read-time guards cannot catch this by construction -> only the UPDATE's own result can
    // Revoking there would tear down a mandate that is now live and paid for
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
    const { sql, texts } = makeQueueSql([[{ status: "pending", merchant_subscription_id: "DKS_S_PAID" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_O_PAID"));

    // The one case where "the SDK said cancel" is a LIE -> the mandate settled -> expiring strands a paid mandate
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

describe("handleWebhook — PhonePe's DOCUMENTED order-event shape (ids under paymentFlow)", () => {
  // For every ORDER event, merchantSubscriptionId and subscriptionId live under payload.paymentFlow
  // The flat fixtures elsewhere in this file are the STATE-CHANGE shape -> both must be exercised
  // Reading only the flat shape acked every real redemption webhook as "Missing merchantSubscriptionId"
  it("grants the month from a redemption.order.completed with ids nested under paymentFlow", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[{ user_id: USER_ID, status: "trialing" }]]);
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
    // The settle stamps the debit-tracking columns off the row's OLD values -> alias-qualified because of the FROM join
    expect(update).toContain("COALESCE(s.first_debit_at, now())");
    expect(update).toContain("s.debit_count + 1");
    // The debited mandate's own price -> a parked one made live again brings its price with it
    expect(update).toContain("s.paid_paise + CASE WHEN s.merchant_subscription_id = $");
    expect(env.KV.put).toHaveBeenCalledWith(
      "txn:subscription.redemption.order.completed:OMO_NEST_1",
      "1",
      expect.anything(),
    );
  });

  it("settles one debit once: the order's claim is in the WHERE, and a second event grants nothing", async () => {
    // PhonePe sends an order AND a transaction event per debit, and the cron settles it too -> each one used to
    // add another ₹199 to debit_count/paid_paise. The first settle clears redemption_order_id; the rest match no row.
    vi.mocked(grantReferralReward).mockClear();
    vi.mocked(reportPostHogFirstConversion).mockClear();
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.redemption.transaction.completed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_R_TWICE_1",
          orderId: "OMO_TWICE_1",
          state: "COMPLETED",
          amount: 19900,
          paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: "DKS_S_TWICE" },
        },
      }),
    );

    expect(res.status).toBe(200);
    const update = (texts.find((t) => t.includes("UPDATE subscriptions AS s")) ?? "").replace(/\s+/g, " ");
    expect(update).toContain("redemption_order_id = NULL");
    expect(update).toContain("AND (s.redemption_order_id = $");
    expect(vi.mocked(grantReferralReward)).not.toHaveBeenCalled();
    expect(vi.mocked(reportPostHogFirstConversion)).not.toHaveBeenCalled();
  });

  it("grants the trial from a setup.order.completed with ids nested under paymentFlow", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[], [{ user_id: USER_ID, status: "trialing" }]]);
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
    // PhonePe's own subscription id must be captured from the NESTED home too, not only the flat one
    expect(update).toContain("phonepe_subscription_id");
  });

  it("acks a redemption failed event WITHOUT touching retry_count — the cron owns dunning", async () => {
    // retry_count is the dunning ladder's INDEX -> the cron's reconcile increments it once per FAILED order
    // That same reconcile schedules the next rung -> a webhook increment advances the index WITHOUT scheduling
    // The result is a skipped rung and a shortened dunning window -> the webhook must acknowledge only
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.redemption.order.failed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_R_FAIL_1",
          orderId: "OMO_FAIL_1",
          state: "FAILED",
          amount: 19900,
          paymentFlow: {
            type: "SUBSCRIPTION_REDEMPTION",
            merchantSubscriptionId: "DKS_S_FAIL",
            subscriptionId: "OMS_FAIL",
          },
        },
      }),
    );

    expect(res.status).toBe(200);
    expect(texts.some((t) => t.includes("retry_count"))).toBe(false);
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
    const { sql, texts } = makeQueueSql([[], [{ user_id: USER_ID, status: "trialing" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);

    const update = (texts.find((t) => t.includes("AND NOT s.offer_switch")) ?? "").replace(/\s+/g, " ");
    expect(update).not.toBe("");
    expect(update).toContain("CASE WHEN s.trial_end IS NULL THEN 'trialing' ELSE 'active' END");
    expect(update).toContain("COALESCE(s.trial_end,");
    // A repeat subscriber's setup is a real ₹199 -> the debit-tracking columns move on the ELSE branch and ONLY there
    expect(update).toContain("ELSE COALESCE(s.first_debit_at, now()) END");
    expect(update).toContain("ELSE s.debit_count + 1 END");
    expect(update).toContain("ELSE s.paid_paise + s.price_paise END");
    // A LOAD-BEARING guard -> without it the webhook/status-poll race hands out a full month off a ₹2 PENNY_DROP
    // And a referral reward with it -> the second writer re-reads the trial_end the first just wrote
    expect(update).toContain("AND s.status = 'pending'");
    expect(update).toContain("RETURNING s.user_id, s.status");
  });

  it("first setup (DB grants 'trialing') → no referral reward", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([[{ user_id: USER_ID, status: "trialing" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);
    expect(vi.mocked(grantReferralReward)).not.toHaveBeenCalled();
  });

  it("repeat setup (DB returns 'active' — ₹199 paid upfront) → referral reward granted", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([[], [{ user_id: USER_ID, status: "active", price_paise: 19900 }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(makeWebhookCtx(env, auth, payload));
    expect(res.status).toBe(200);
    expect(vi.mocked(grantReferralReward)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(grantReferralReward).mock.calls[0][1]).toBe(USER_ID);
  });
});

// THREE surfaces release a claim and they MUST agree -> a user reaches them by route, not by choice
// The failed-setup webhook, the /payments/status reconcile, and /payments/abandon
// A rule that holds on two of them is the same outage for whoever hits the third
// These assert the CONDITIONAL, not merely that 'expired' appears somewhere
// The old assertions matched `'expired'` as a SUBSTRING, which both the flat write and the CASE satisfy
// They passed throughout the incident -> the NEGATIVE assertion is the load-bearing one
function expectRestoreRule(update: string | undefined, path: string): void {
  expect(update, `${path}: no release UPDATE was captured`).toBeDefined();
  // The one shared release qualifies every column with its alias -> compare the rule, not the alias
  const sql = (update as string).replace(/\s+/g, " ").replace(/\bs\./g, "");
  expect(sql, `${path}: must gate on a live period`).toContain(
    "CASE WHEN current_period_end IS NOT NULL AND current_period_end > now()",
  );
  expect(sql, `${path}: a live period must restore, not expire`).toContain(
    "THEN 'cancelled' ELSE 'expired' END",
  );
  expect(sql, `${path}: unconditional expire strips a paid period`).not.toMatch(
    /SET\s+status\s*=\s*'expired'/,
  );
  // A PARKED mandate (re-subscribe over a lapsed trial) outranks both -> the row goes back to it, ladder intact
  expect(sql, `${path}: a parked mandate must be restored, not cancelled`).toContain(
    "WHEN superseded_mandate_id IS NOT NULL",
  );
  expect(sql, `${path}: the parked id must become the live one`).toContain(
    "merchant_subscription_id = COALESCE(superseded_mandate_id, merchant_subscription_id)",
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
    // A resubscribe mid-trial -> the claim is 'pending' but current_period_end is still ahead
    // That is precisely the row the incident expired -> it must land back on 'cancelled'
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
    // The response must report what the DB DECIDED, never a hardcoded guess -> the app paywalls straight off this field
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
    const cancelledAt = new Date("2026-08-26T12:00:00.000Z");
    const { sql, texts } = makeQueueSql([
      [{ merchant_subscription_id: "DKS_S_CANCEL", status: "trialing" }],
      [{ updated_at: cancelledAt, price_paise: 19900, merchant_subscription_id: "DKS_S_CANCEL" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(env, "DKS_S_CANCEL");
    expect(texts.find((t) => t.includes("'cancelled'"))).toBeDefined();
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledTimes(1);
    // occurredAt is the UPDATE's own RETURNED instant -> the stable half of PostHog's [timestamp, …, uuid] dedup key
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledWith(env, {
      userId: USER_ID,
      merchantSubId: "DKS_S_CANCEL",
      reason: "user_cancel",
      priorStatus: "trialing",
      occurredAt: cancelledAt,
      pricePaise: 19900,
    });
  });

  it("a cancel mid-switch reports the churn of the parked ₹199 with the status it had, never 'pending'", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [
        {
          merchant_subscription_id: "DKS_HS_NEW99",
          superseded_mandate_id: "DKS_S_OLD199",
          status: "pending",
          offer_switch: true,
          trial_end: new Date(Date.now() - 20 * 86_400_000).toISOString(),
          current_period_end: new Date(Date.now() + 5 * 86_400_000).toISOString(),
        },
      ],
      [{ updated_at: new Date(), price_paise: 19900, merchant_subscription_id: "DKS_S_OLD199" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalledWith(
      env,
      expect.objectContaining({ merchantSubId: "DKS_S_OLD199", priorStatus: "active", pricePaise: 19900 }),
    );
  });

  it("does not report when the row was already cancelled (no state change)", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([[{ merchant_subscription_id: "DKS_S_DONE", status: "cancelled" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });

  it("does not report when PhonePe refused the revoke (nothing was cancelled)", async () => {
    vi.mocked(revokeMandateTolerant).mockResolvedValueOnce(false);
    const env = makeEnv();
    const { sql } = makeQueueSql([[{ merchant_subscription_id: "DKS_S_REFUSED", status: "active" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(502);
    expect(posthog.reportPostHogSubscriptionCancel).not.toHaveBeenCalled();
  });
});

describe("re-subscribe parks the live mandate (superseded_mandate_id)", () => {
  beforeEach(() => {
    vi.mocked(revokeMandateTolerant).mockClear();
    vi.mocked(getOrderStatus).mockReset();
    vi.mocked(getOrderStatus).mockResolvedValue({ state: "PENDING", orderId: "PP_ORDER_1" } as never);
  });

  const lapsedTrial = (over: Record<string, unknown> = {}) => ({
    trial_end: new Date(Date.now() - 2 * 86_400_000).toISOString(),
    status: "trialing",
    merchant_subscription_id: "DKS_S_OLD",
    superseded_mandate_id: null,
    current_period_end: new Date(Date.now() - 2 * 86_400_000).toISOString(),
    updated_at: new Date(Date.now() - 3 * 86_400_000).toISOString(),
    ...over,
  });

  it("initiate over a lapsed trialing row parks its mandate and does NOT revoke it", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[lapsedTrial()], [], [lapsedTrial()], []]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    expect(res.status).toBe(200);
    const upsert = texts.find((t) => t.includes("INSERT INTO subscriptions"));
    expect(upsert).toContain("superseded_mandate_id    = EXCLUDED.superseded_mandate_id");
    const upsertCall = (sql as unknown as { mock: { calls: unknown[][] } }).mock.calls.find(
      (call) =>
        Array.isArray(call[0]) && (call[0] as string[]).join("$").includes("INSERT INTO subscriptions"),
    );
    expect(upsertCall).toBeDefined();
    expect((upsertCall as unknown[]).slice(1)).toContain("DKS_S_OLD");
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();
  });

  it("initiate stores the tap's analytics context, sanitised, and never refuses over it", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[], [], []]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(
      makeInitiateCtx(env, token, {
        plan: "monthly",
        context: { paywall_source: "apply", checkout_n: 2, nested: { x: 1 }, "Bad Key": 1 },
      }),
    );

    expect(res.status).toBe(200);
    expect(texts.find((t) => t.includes("INSERT INTO subscriptions"))).toContain(
      "checkout_context         = EXCLUDED.checkout_context",
    );
    expect(texts.find((t) => t.includes("INSERT INTO subscriptions"))).toContain("::text::jsonb");
    const upsertCall = (sql as unknown as { mock: { calls: unknown[][] } }).mock.calls.find(
      (call) =>
        Array.isArray(call[0]) && (call[0] as string[]).join("$").includes("INSERT INTO subscriptions"),
    );
    expect((upsertCall as unknown[]).slice(1)).toContain(
      JSON.stringify({ paywall_source: "apply", checkout_n: 2 }),
    );

    const junk = await handleInitiate(makeInitiateCtx(env, token, { plan: "monthly", context: "nope" }));
    expect(junk.status).toBe(200);
  });

  it("initiate over an expired row (ladder exhausted) still revokes on the spot", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [lapsedTrial({ status: "expired" })],
      [],
      [lapsedTrial({ status: "expired" })],
      [],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleInitiate(makeInitiateCtx(env, token));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_OLD");
  });

  it("abandon hands the row back to the parked mandate and revokes only the new one", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ status: "pending", merchant_subscription_id: "DKS_S_NEW" }],
      [{ status: "trialing", released_mandate_id: "DKS_S_NEW" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleAbandon(makeAbandonCtx(env, token, "DKS_S_NEW_ORDER"));

    expect(res.status).toBe(200);
    const update = (texts.find((t) => t.includes("UPDATE subscriptions")) ?? "").replace(/\s+/g, " ");
    expect(update).toContain("WHEN s.superseded_mandate_id IS NOT NULL");
    expect(update).toContain("THEN 'active' ELSE 'trialing' END");
    expect(update).toContain(
      "merchant_subscription_id = COALESCE(s.superseded_mandate_id, s.merchant_subscription_id)",
    );
    // The parked mandate comes back at ITS price -> a ₹99 parked under a ₹199 attempt stays ₹99
    expect(update).toContain("price_paise = CASE WHEN s.superseded_mandate_id IS NOT NULL");
    expect(update).toContain("superseded_mandate_id = NULL");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_NEW");
  });

  it("setup completed webhook revokes the parked mandate AFTER the grant, once", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [], // the offer switch → not an offer row
      // The grant, self-joined so the PRIOR parked id rides back
      [{ user_id: USER_ID, status: "active", price_paise: 19900, stale_mandate_id: "DKS_S_OLD" }],
      [],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.setup.order.completed",
        payload: {
          state: "COMPLETED",
          merchantId: "M",
          orderId: "PP_ORDER_RESUB_1",
          merchantOrderId: "DKS_S_NEW_ORDER",
          merchantSubscriptionId: "DKS_S_NEW",
          subscriptionId: "PP_SUB_NEW",
          amount: 19900,
        },
      }),
    );

    expect(res.status).toBe(200);
    const release = (
      texts.find((t) => t.includes("AND NOT s.offer_switch") && t.includes("AS stale_mandate_id")) ?? ""
    ).replace(/\s+/g, " ");
    expect(release).toContain("AND NOT s.offer_switch");
    expect(release).toContain("superseded_mandate_id = NULL");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledTimes(1);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_OLD");
  });

  it("a debit on the PARKED mandate grants, points the row back at it and retires the unapproved one", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([
      [{ user_id: USER_ID, prior_status: "pending", prior_mandate_id: "DKS_S_NEW" }],
      [],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.redemption.order.completed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_R_OLD_1",
          orderId: "OMO_OLD_1",
          state: "COMPLETED",
          amount: 19900,
          paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: "DKS_S_OLD" },
        },
      }),
    );

    expect(res.status).toBe(200);
    const update = (texts.find((t) => t.includes("UPDATE subscriptions AS s")) ?? "").replace(/\s+/g, " ");
    expect(update).toContain("OR s.superseded_mandate_id = $");
    expect(update).toContain("merchant_subscription_id = $");
    expect(update).toContain("superseded_mandate_id = NULL");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_NEW");
  });

  it("a redemption event whose root state is not COMPLETED grants nothing (PhonePe: use payload.state)", async () => {
    const env = makeEnv();
    const { sql, texts } = makeQueueSql([[]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const auth = await webhookAuthHeader("u", "p");
    const res = await handleWebhook(
      makeWebhookCtx(env, auth, {
        event: "subscription.redemption.transaction.completed",
        payload: {
          merchantId: "M",
          merchantOrderId: "DKS_R_PEND_1",
          orderId: "OMO_PEND_1",
          state: "PENDING",
          amount: 19900,
          paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: "DKS_S_PEND" },
        },
      }),
    );

    expect(res.status).toBe(200);
    expect(texts.some((t) => t.includes("UPDATE subscriptions"))).toBe(false);
  });

  it("status heals a never-converted row whose redemption order COMPLETED at PhonePe", async () => {
    const env = makeEnv();
    vi.mocked(getOrderStatus).mockResolvedValueOnce({ state: "COMPLETED", orderId: "OMO_HEAL" } as never);
    const past = new Date(Date.now() - 3 * 86_400_000).toISOString();
    const { sql, texts } = makeQueueSql([
      [
        {
          id: "sub-heal",
          user_id: USER_ID,
          status: "cancelled",
          plan: "monthly",
          merchant_subscription_id: "DKS_S_HEAL",
          merchant_order_id: "DKS_S_HEAL_ORDER",
          phonepe_order_id: null,
          phonepe_subscription_id: null,
          current_period_end: past,
          trial_end: past,
          next_debit_at: null,
          notified_at: null,
          retry_count: 0,
          updated_at: past,
          redemption_order_id: "DKS_R_HEAL_1",
          superseded_mandate_id: null,
        },
      ],
      [
        {
          status: "active",
          current_period_end: new Date().toISOString(),
          next_debit_at: new Date().toISOString(),
          merchant_subscription_id: "DKS_S_HEAL",
          prior_mandate_id: "DKS_S_HEAL",
        },
      ],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleStatus(makeAbandonCtx(env, token, "ignored"));

    expect(res.status).toBe(200);
    expect(((await res.json()) as { status: string }).status).toBe("active");
    expect(vi.mocked(getOrderStatus)).toHaveBeenCalledWith(expect.anything(), "DKS_R_HEAL_1");
    const heal = (
      texts.find((t) => t.includes("UPDATE subscriptions AS s") && t.includes("s.redemption_order_id = $")) ??
      ""
    ).replace(/\s+/g, " ");
    expect(heal).toContain("s.paid_paise + CASE WHEN s.superseded_mandate_id IS NOT NULL");
    expect(heal).toContain("(s.current_period_end IS NULL OR s.current_period_end <= s.trial_end)");
    expect(vi.mocked(revokeMandateTolerant)).not.toHaveBeenCalled();
    expect(posthog.reportPostHogFirstConversion).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ transactionId: "DKS_R_HEAL_1" }),
    );
  });

  it("status leaves a converted row alone even with an old redemption order on file", async () => {
    const env = makeEnv();
    const trialEnd = new Date(Date.now() - 10 * 86_400_000).toISOString();
    const { sql } = makeQueueSql([
      [
        {
          id: "sub-paid",
          user_id: USER_ID,
          status: "cancelled",
          merchant_subscription_id: "DKS_S_PAID",
          merchant_order_id: "DKS_S_PAID_ORDER",
          current_period_end: new Date(Date.now() + 5 * 86_400_000).toISOString(),
          trial_end: trialEnd,
          redemption_order_id: "DKS_R_PAID_1",
          superseded_mandate_id: null,
          updated_at: trialEnd,
        },
      ],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleStatus(makeAbandonCtx(env, token, "ignored"));

    expect(res.status).toBe(200);
    expect(vi.mocked(getOrderStatus)).not.toHaveBeenCalled();
  });

  it("cancel revokes the parked mandate as well as the live one", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ merchant_subscription_id: "DKS_S_NEW", superseded_mandate_id: "DKS_S_OLD", status: "pending" }],
      [{ updated_at: new Date().toISOString() }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;

    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const res = await handleCancel(makeInitiateCtx(env, token, {}));

    expect(res.status).toBe(200);
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_NEW");
    expect(vi.mocked(revokeMandateTolerant)).toHaveBeenCalledWith(expect.anything(), "DKS_S_OLD");
  });
});

describe("handleWebhook — PostHog never delays PhonePe's acknowledgement", () => {
  // Cloudflare's context docs: analytics goes to waitUntil, after the response. A slow capture held every 200 back
  function ctxCollectingWaitUntil(env: Env, authHeader: string, payload: unknown) {
    const background: Promise<unknown>[] = [];
    const c = makeWebhookCtx(env, authHeader, payload) as unknown as {
      executionCtx: { waitUntil: (p: Promise<unknown>) => void };
    };
    c.executionCtx = { waitUntil: (p) => background.push(p) };
    return { c: c as unknown as Context<{ Bindings: Env }>, background };
  }

  const never = () => new Promise<void>(() => {});

  it("acks a revoke while the subscription_cancel capture is still in flight", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([[], [{ user_id: USER_ID, prior_status: "trialing" }]]);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    posthog.reportPostHogSubscriptionCancel.mockImplementationOnce(never);

    const { c, background } = ctxCollectingWaitUntil(env, await webhookAuthHeader("u", "p"), {
      event: "subscription.revoked",
      payload: { merchantSubscriptionId: "DKS_S_SLOWPH", state: "REVOKED" },
    });
    const res = await Promise.race([
      handleWebhook(c),
      new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 200)),
    ]);

    expect(res).not.toBe("timeout");
    expect((res as Response).status).toBe(200);
    expect(posthog.reportPostHogSubscriptionCancel).toHaveBeenCalled();
    expect(background.length).toBeGreaterThan(1);
  });

  it("acks a settled redemption while the subscription_active capture is still in flight", async () => {
    const env = makeEnv();
    const { sql } = makeQueueSql([
      [{ user_id: USER_ID, prior_status: "trialing", prior_mandate_id: "DKS_S_SLOWPH2" }],
    ]);
    (env as unknown as { _testSql: unknown })._testSql = sql;
    posthog.reportPostHogFirstConversion.mockImplementationOnce(never);

    const { c } = ctxCollectingWaitUntil(env, await webhookAuthHeader("u", "p"), {
      event: "subscription.redemption.order.completed",
      payload: {
        merchantOrderId: "DKS_R_SLOWPH2_X_0001",
        orderId: "OMO_SLOWPH2",
        state: "COMPLETED",
        amount: 19900,
        paymentFlow: { type: "SUBSCRIPTION_REDEMPTION", merchantSubscriptionId: "DKS_S_SLOWPH2" },
      },
    });
    const res = await Promise.race([
      handleWebhook(c),
      new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 200)),
    ]);

    expect(res).not.toBe("timeout");
    expect(posthog.reportPostHogFirstConversion).toHaveBeenCalled();
  });
});
