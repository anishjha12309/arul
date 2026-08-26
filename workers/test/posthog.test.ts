/**
 * Unit tests for lib/posthog.ts — server-side subscription_active capture.
 * Mocks KV and global fetch — no network.
 *
 * The invariant under test everywhere: reportPostHogFirstConversion NEVER
 * throws. It runs inside billing state transitions (webhook + autopay cron),
 * where an analytics failure must not cost a user their paid month.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  reportPostHogFirstConversion,
  reportPostHogSubscriptionCancel,
} from "../src/lib/posthog.js";
import type { Env } from "../src/env.js";

function makeEnv(overrides: Partial<Record<string, unknown>> = {}): Env {
  const store = new Map<string, string>();
  return {
    POSTHOG_API_KEY: "phc_test",
    POSTHOG_HOST: "https://us.i.posthog.com",
    KV: {
      get: vi.fn(async (k: string) => store.get(k) ?? null),
      put: vi.fn(async (k: string, v: string) => void store.set(k, v)),
    },
    ...overrides,
  } as unknown as Env;
}

const CONVERSION = { userId: "user-1", transactionId: "DKS_x_R_1", amountPaise: 19900 };

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("reportPostHogFirstConversion", () => {
  it("captures subscription_active for the user's distinct_id with the client property convention", async () => {
    const env = makeEnv();

    await reportPostHogFirstConversion(env, CONVERSION);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://us.i.posthog.com/i/v0/e");
    const body = JSON.parse(init.body as string);
    expect(body.api_key).toBe("phc_test");
    expect(body.event).toBe("subscription_active");
    // distinct_id = users.id — the same value the app identifies with at login.
    expect(body.distinct_id).toBe("user-1");
    expect(body.uuid).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(body.properties).toMatchObject({
      plan: "monthly",
      order_id: "DKS_x_R_1",
      value: 199,
      currency: "INR",
    });
  });

  it("sends the SAME uuid for the same transaction — dedup under KV eventual consistency", async () => {
    const env1 = makeEnv();
    const env2 = makeEnv(); // fresh KV → the second send is not KV-suppressed

    await reportPostHogFirstConversion(env1, CONVERSION);
    await reportPostHogFirstConversion(env2, CONVERSION);

    const uuid1 = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string).uuid;
    const uuid2 = JSON.parse((fetchMock.mock.calls[1] as [string, RequestInit])[1].body as string).uuid;
    expect(uuid1).toBe(uuid2);
  });

  it("marks the transaction in KV on success and skips a repeat report", async () => {
    const env = makeEnv();

    await reportPostHogFirstConversion(env, CONVERSION);
    await reportPostHogFirstConversion(env, CONVERSION); // webhook + cron double-settle

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(env.KV.put).toHaveBeenCalledWith(
      "ph:subscription_active:DKS_x_R_1",
      "1",
      expect.objectContaining({ expirationTtl: expect.any(Number) }),
    );
  });

  it("does NOT mark KV on a rejected capture, so a retry can succeed", async () => {
    fetchMock.mockResolvedValue(new Response("bad", { status: 401 }));
    const env = makeEnv();

    await reportPostHogFirstConversion(env, CONVERSION);

    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("skips silently when POSTHOG_API_KEY is absent (tests / unconfigured envs)", async () => {
    const env = makeEnv({ POSTHOG_API_KEY: undefined });

    await reportPostHogFirstConversion(env, CONVERSION);

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("defaults the host when POSTHOG_HOST is unset", async () => {
    const env = makeEnv({ POSTHOG_HOST: undefined });

    await reportPostHogFirstConversion(env, CONVERSION);

    expect((fetchMock.mock.calls[0] as [string])[0]).toBe("https://us.i.posthog.com/i/v0/e");
  });

  it("falls back to ₹199 when the payload omitted the amount", async () => {
    const env = makeEnv();

    await reportPostHogFirstConversion(env, { ...CONVERSION, amountPaise: null });

    const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
    expect(body.properties.value).toBe(199);
  });

  it("never throws — fetch failure", async () => {
    fetchMock.mockRejectedValue(new Error("network down"));
    const env = makeEnv();

    await expect(reportPostHogFirstConversion(env, CONVERSION)).resolves.toBeUndefined();
  });

  it("never throws — KV failure", async () => {
    const env = makeEnv();
    (env.KV.get as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("kv down"));

    await expect(reportPostHogFirstConversion(env, CONVERSION)).resolves.toBeUndefined();
  });
});

describe("reportPostHogSubscriptionCancel", () => {
  const CANCEL = {
    userId: "user-1",
    merchantSubId: "DKS_S_1",
    reason: "user_cancel" as const,
    priorStatus: "active",
  };

  it("captures subscription_cancel with reason/prior_status/during_trial on the user distinct_id", async () => {
    const env = makeEnv();
    await reportPostHogSubscriptionCancel(env, CANCEL);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://us.i.posthog.com/i/v0/e");
    const body = JSON.parse(init.body as string);
    expect(body.event).toBe("subscription_cancel");
    expect(body.distinct_id).toBe("user-1");
    expect(body.uuid).toMatch(/^[0-9a-f-]{36}$/);
    expect(body.properties).toMatchObject({
      plan: "monthly",
      reason: "user_cancel",
      prior_status: "active",
      during_trial: false,
      merchant_subscription_id: "DKS_S_1",
      $lib: "arul-worker",
    });
    expect(env.KV.put).toHaveBeenCalledWith(
      "ph:subscription_cancel:DKS_S_1",
      "1",
      expect.anything(),
    );
  });

  it("flags a trial-time cancel as during_trial", async () => {
    const env = makeEnv();
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, priorStatus: "trialing" });
    const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
    expect(body.properties.during_trial).toBe(true);
  });

  it("drops a cancel whose prior status was not a live subscription", async () => {
    const env = makeEnv();
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, priorStatus: "cancelled" });
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, priorStatus: "expired" });
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, priorStatus: "pending" });
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, priorStatus: null });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("reports one event per mandate — the second call for the same id is a no-op", async () => {
    const env = makeEnv();
    await reportPostHogSubscriptionCancel(env, CANCEL);
    await reportPostHogSubscriptionCancel(env, { ...CANCEL, reason: "webhook_revoked" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("keys the account-deletion path on the user when the row had no mandate id", async () => {
    const env = makeEnv();
    await reportPostHogSubscriptionCancel(env, {
      ...CANCEL,
      merchantSubId: null,
      reason: "account_deleted",
    });
    expect(env.KV.put).toHaveBeenCalledWith(
      "ph:subscription_cancel:user:user-1",
      "1",
      expect.anything(),
    );
  });

  it("never throws — a network failure is logged and swallowed", async () => {
    fetchMock.mockRejectedValueOnce(new Error("posthog down"));
    const env = makeEnv();
    await expect(reportPostHogSubscriptionCancel(env, CANCEL)).resolves.toBeUndefined();
    expect(env.KV.put).not.toHaveBeenCalled();
  });

  it("skips silently without POSTHOG_API_KEY", async () => {
    const env = makeEnv({ POSTHOG_API_KEY: undefined });
    await reportPostHogSubscriptionCancel(env, CANCEL);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
