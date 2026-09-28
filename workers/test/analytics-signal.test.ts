/**
 * Analytics context the app sends beside a checkout tap or a paywall view, read by PostHog's warehouse.
 * The contract: junk is dropped, never an error, and only the verified user's row is ever written
 */

import { describe, it, expect, vi } from "vitest";
import { sanitizeAnalyticsContext } from "../src/lib/analytics-context.js";
import { handleCheckoutEvent, handlePaywallView } from "../src/routes/me.js";
import { requestSignal } from "../src/lib/request-signal.js";
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
    expect(text).toContain("views        = paywall_views.views + 1");
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

const CF = {
  asOrganization: "Reliance Jio Infocomm Limited",
  asn: 55836,
  clientTcpRtt: 48,
  colo: "MAA",
  regionCode: "TN",
  city: "Chennai",
  latitude: "13.08",
  httpProtocol: "HTTP/2",
  tlsVersion: "TLSv1.3",
};

describe("requestSignal", () => {
  it("reads carrier and link quality, never city or coordinates", () => {
    expect(requestSignal({ cf: CF } as unknown as Request)).toEqual({
      isp: "Reliance Jio Infocomm Limited",
      rtt_ms: 48,
      colo: "MAA",
      region_code: "TN",
      asn: 55836,
      http: "HTTP/2",
      tls: "TLSv1.3",
    });
  });

  it("is empty off the edge, where request.cf does not exist", () => {
    expect(requestSignal({} as Request)).toEqual({});
  });
});

describe("paywall exits and checkout events", () => {
  it("an exit report updates the view it ends, never counts a new one", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    const res = await handlePaywallView(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: sql }),
        token,
        jsonBody: { source: "apply", exit: "back", dwell_s: 12.4 },
      }),
    );
    expect(res.status).toBe(200);
    const [strings, ...values] = capturedArgs[0] as [string[], ...unknown[]];
    expect(strings.join("?")).toContain("UPDATE paywall_views");
    expect(strings.join("?")).not.toContain("views + 1");
    expect(values).toEqual(["back", 12, USER_ID, "apply"]);
  });

  it("a view stores the edge's connection beside the app's context", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    await handlePaywallView(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: sql }),
        token,
        cf: CF,
        jsonBody: { source: "apply", context: { paywall_n: 1 } },
      }),
    );
    const stored = JSON.parse((capturedArgs[0] as unknown[])[3] as string);
    expect(stored).toMatchObject({ paywall_n: 1, isp: "Reliance Jio Infocomm Limited", rtt_ms: 48 });
    expect(stored.city).toBeUndefined();
  });

  it("a checkout event is appended with its reason, order and the connection", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    const res = await handleCheckoutEvent(
      makeCtx({
        env: makeEnv({ JWT_SECRET, _testSql: sql }),
        token,
        cf: CF,
        jsonBody: {
          kind: "failed:user_cancelled",
          merchant_order_id: "DKS_S_ABCD1234_MUK292U1_62CC",
          context: { s_in_upi_app: 41 },
        },
      }),
    );
    expect(res.status).toBe(200);
    const [strings, ...values] = capturedArgs[0] as [string[], ...unknown[]];
    expect(strings.join("?")).toContain("INSERT INTO checkout_events");
    expect(strings.join("?")).toContain("::text::jsonb");
    expect(values.slice(0, 3)).toEqual([USER_ID, "DKS_S_ABCD1234_MUK292U1_62CC", "failed:user_cancelled"]);
    expect(JSON.parse(values[3] as string)).toMatchObject({ s_in_upi_app: 41, colo: "MAA" });
  });

  it("a checkout event without a valid kind is refused and writes nothing", async () => {
    const token = await signAccessToken(USER_ID, JWT_SECRET);
    const { sql, capturedArgs } = makeMockSql([]);
    for (const body of [{}, { kind: "" }, { kind: "Failed Reason" }]) {
      const res = await handleCheckoutEvent(
        makeCtx({ env: makeEnv({ JWT_SECRET, _testSql: sql }), token, jsonBody: body }),
      );
      expect(res.status).toBe(400);
    }
    expect(capturedArgs).toHaveLength(0);
  });
});
