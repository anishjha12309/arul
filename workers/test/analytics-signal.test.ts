/**
 * Analytics context the app sends beside a checkout tap or a paywall view, read by PostHog's warehouse.
 * The contract: junk is dropped, never an error, and only the verified user's row is ever written
 */

import { describe, it, expect, vi } from "vitest";
import { sanitizeAnalyticsContext } from "../src/lib/analytics-context.js";
import { handlePaywallView } from "../src/routes/me.js";
import { signAccessToken } from "../src/lib/jwt.js";
import { makeEnv, makeCtx, makeMockSql } from "./_ctx.js";

// getDb(env) is replaced -> handlers reach the injected mock sql through env._testSql
vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

const JWT_SECRET = "test-jwt-secret-must-be-at-least-32-bytes!!";
const USER_ID = "11111111-1111-1111-1111-111111111111";

describe("sanitizeAnalyticsContext", () => {
  it("keeps flat scalars under valid keys and drops everything else", () => {
    expect(
      sanitizeAnalyticsContext({
        paywall_source: "apply",
        checkout_n: 2,
        net_validated: false,
        nested: { x: 1 },
        list: [1],
        nothing: null,
        infinite: Number.POSITIVE_INFINITY,
        "Bad Key": 1,
        long: "x".repeat(150),
      }),
    ).toEqual({ paywall_source: "apply", checkout_n: 2, net_validated: false, long: "x".repeat(100) });
  });

  it("answers null for anything that is not an object, or leaves nothing", () => {
    for (const raw of [null, undefined, "x", 3, [1, 2], {}, { nested: {} }]) {
      expect(sanitizeAnalyticsContext(raw)).toBeNull();
    }
  });

  it("caps the number of keys", () => {
    const wide = Object.fromEntries(Array.from({ length: 80 }, (_, i) => [`k${i}`, i]));
    expect(Object.keys(sanitizeAnalyticsContext(wide) ?? {})).toHaveLength(60);
  });
});

describe("POST /me/paywall-view", () => {
  it("401s without a token", async () => {
    const { sql } = makeMockSql([]);
    const res = await handlePaywallView(
      makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: sql }), jsonBody: { source: "apply" } }),
    );
    expect(res.status).toBe(401);
  });

  it("upserts one row per user per source, counting views, with the context as jsonb", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    const res = await handlePaywallView(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: sql }),
        token,
        jsonBody: { source: "trial_nudge", context: { variant: "trial", paywall_n: 3, bad: { x: 1 } } },
      }),
    );
    expect(res.status).toBe(200);
    const [strings, ...values] = capturedArgs[0] as [string[], ...unknown[]];
    const text = strings.join("?");
    expect(text).toContain("INSERT INTO paywall_views");
    expect(text).toContain("ON CONFLICT (user_id, source)");
    expect(text).toContain("views   = paywall_views.views + 1");
    // jsonb bound as text: postgres.js would JSON-encode a jsonb-typed parameter a second time
    expect(text).toContain("::text::jsonb");
    expect(values).toEqual([USER_ID, "trial_nudge", JSON.stringify({ variant: "trial", paywall_n: 3 })]);
  });

  it("400s on a missing or malformed source and writes nothing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    for (const body of [{}, { source: "" }, { source: "Apply Now" }, { source: 7 }]) {
      const res = await handlePaywallView(
        makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: sql }), token, jsonBody: body }),
      );
      expect(res.status).toBe(400);
    }
    expect(capturedArgs).toHaveLength(0);
  });
});
