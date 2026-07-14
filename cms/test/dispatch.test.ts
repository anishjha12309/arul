/**
 * PhonePe webhook dispatcher — POST /payments/webhook (outside /admin, no
 * session cookie). Routing rule: merchant id starting with "DKS_" (Arul's
 * phonepe.ts id scheme) → ARUL_API service binding; everything else — other
 * merchant ids, missing ids, unparseable bodies — → PAKIZA_API (the incumbent
 * registrant) with a console.warn. The request is forwarded verbatim (method,
 * path, headers incl. Authorization, exact raw body bytes) and the downstream
 * response is returned as-is.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { makeEnv, execCtx, stubFetch } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import worker from "../src/index.js";
import { extractMerchantId } from "../src/payments-dispatch.js";

const WEBHOOK_URL = "https://api.hsrutility.com/payments/webhook";
const PHONEPE_AUTH = "a".repeat(64); // SHA256(user:pass) hex, opaque to the dispatcher

interface MockBinding {
  fetcher: Fetcher;
  fetch: ReturnType<typeof vi.fn>;
}

function makeBinding(status = 200, body = "downstream-ok"): MockBinding {
  const fetch = vi.fn(async (_req: Request) => new Response(body, { status }));
  return { fetcher: { fetch } as unknown as Fetcher, fetch };
}

function makeDispatchEnv(arul: MockBinding, pakiza: MockBinding): Env {
  return makeEnv({
    overrides: { ARUL_API: arul.fetcher, PAKIZA_API: pakiza.fetcher },
  }).env;
}

const post = (env: Env, body: string) =>
  worker.fetch(
    new Request(WEBHOOK_URL, {
      method: "POST",
      headers: { Authorization: PHONEPE_AUTH, "content-type": "application/json" },
      body,
    }),
    env,
    execCtx,
  );

beforeEach(() => {
  vi.unstubAllGlobals();
  stubFetch(); // nothing may reach a real endpoint
  vi.restoreAllMocks();
});

describe("extractMerchantId", () => {
  it("prefers payload.merchantOrderId, falls back to payload.merchantSubscriptionId", () => {
    expect(
      extractMerchantId(
        JSON.stringify({
          event: "checkout.order.completed",
          payload: { state: "COMPLETED", merchantOrderId: "DKS_O_a1b2c3d4_x_ff", merchantSubscriptionId: "DKS_S_a1b2c3d4_x" },
        }),
      ),
    ).toBe("DKS_O_a1b2c3d4_x_ff");
    expect(
      extractMerchantId(
        JSON.stringify({ type: "SUBSCRIPTION_REVOKED", payload: { state: "REVOKED", merchantSubscriptionId: "DKS_S_a1b2c3d4_x" } }),
      ),
    ).toBe("DKS_S_a1b2c3d4_x");
  });

  it("returns null for parse failures, non-objects and missing ids", () => {
    expect(extractMerchantId("{not json")).toBeNull();
    expect(extractMerchantId('"just a string"')).toBeNull();
    expect(extractMerchantId(JSON.stringify({ payload: {} }))).toBeNull();
    expect(extractMerchantId(JSON.stringify({ event: "x" }))).toBeNull();
  });
});

describe("POST /payments/webhook dispatcher", () => {
  it("routes a DKS_ order to ARUL_API verbatim (body + auth header); PAKIZA_API untouched", async () => {
    const arul = makeBinding(200, "arul-ack");
    const pakiza = makeBinding();
    const env = makeDispatchEnv(arul, pakiza);
    const body = JSON.stringify({
      event: "checkout.order.completed",
      payload: { state: "COMPLETED", merchantOrderId: "DKS_O_a1b2c3d4_lz_ff", merchantSubscriptionId: "DKS_S_a1b2c3d4_lz" },
    });

    const res = await post(env, body);

    // Downstream response returned as-is.
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("arul-ack");

    expect(arul.fetch).toHaveBeenCalledTimes(1);
    expect(pakiza.fetch).not.toHaveBeenCalled();

    const forwarded = arul.fetch.mock.calls[0]![0] as Request;
    expect(forwarded.method).toBe("POST");
    expect(new URL(forwarded.url).pathname).toBe("/payments/webhook");
    expect(forwarded.headers.get("Authorization")).toBe(PHONEPE_AUTH);
    expect(await forwarded.text()).toBe(body); // exact raw bytes
  });

  it("routes a non-DKS merchant order to PAKIZA_API; ARUL_API untouched", async () => {
    const arul = makeBinding();
    const pakiza = makeBinding(200, "pakiza-ack");
    const env = makeDispatchEnv(arul, pakiza);
    const body = JSON.stringify({
      event: "checkout.order.completed",
      payload: { state: "COMPLETED", merchantOrderId: "PKZ_O_deadbeef_lz_00" },
    });

    const res = await post(env, body);

    expect(res.status).toBe(200);
    expect(await res.text()).toBe("pakiza-ack");
    expect(pakiza.fetch).toHaveBeenCalledTimes(1);
    expect(arul.fetch).not.toHaveBeenCalled();

    const forwarded = pakiza.fetch.mock.calls[0]![0] as Request;
    expect(forwarded.headers.get("Authorization")).toBe(PHONEPE_AUTH);
    expect(await forwarded.text()).toBe(body);
  });

  it("routes malformed JSON to PAKIZA_API verbatim and warns", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const arul = makeBinding();
    const pakiza = makeBinding(200, "pakiza-ack");
    const env = makeDispatchEnv(arul, pakiza);
    const body = "this is {not json at all";

    const res = await post(env, body);

    expect(res.status).toBe(200);
    expect(pakiza.fetch).toHaveBeenCalledTimes(1);
    expect(arul.fetch).not.toHaveBeenCalled();
    expect(await (pakiza.fetch.mock.calls[0]![0] as Request).text()).toBe(body);
    expect(warn).toHaveBeenCalled();
  });

  it("requires NO session cookie (dispatches while /admin would redirect)", async () => {
    const arul = makeBinding();
    const pakiza = makeBinding(200, "pakiza-ack");
    const env = makeDispatchEnv(arul, pakiza);

    // No cookie header anywhere in `post` — a 200 (not a 302 to the login
    // page) proves the dispatcher sits outside the session guard.
    const res = await post(env, JSON.stringify({ payload: { merchantOrderId: "OTHER_1" } }));
    expect(res.status).toBe(200);
    expect(res.headers.get("location")).toBeNull();
  });

  it("rejects GET /payments/webhook (POST only)", async () => {
    const arul = makeBinding();
    const pakiza = makeBinding();
    const env = makeDispatchEnv(arul, pakiza);

    const res = await worker.fetch(new Request(WEBHOOK_URL), env, execCtx);
    expect([404, 405]).toContain(res.status);
    expect(arul.fetch).not.toHaveBeenCalled();
    expect(pakiza.fetch).not.toHaveBeenCalled();
  });

  it("returns 502 JSON when the downstream forward throws", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const fetch = vi.fn(async () => {
      throw new Error("binding exploded");
    });
    const arul = { fetcher: { fetch } as unknown as Fetcher, fetch };
    const pakiza = makeBinding();
    const env = makeDispatchEnv(arul, pakiza);

    const res = await post(
      env,
      JSON.stringify({ payload: { merchantOrderId: "DKS_O_a1b2c3d4_lz_ff" } }),
    );
    expect(res.status).toBe(502);
    const json = (await res.json()) as { error: { code: string } };
    expect(json.error.code).toBe("dispatch_failed");
    expect(err).toHaveBeenCalled();
  });

  it("returns 502 JSON when the target binding is missing", async () => {
    const { env } = makeEnv(); // no ARUL_API / PAKIZA_API bindings
    const res = await post(
      env,
      JSON.stringify({ payload: { merchantOrderId: "DKS_O_a1b2c3d4_lz_ff" } }),
    );
    expect(res.status).toBe(502);
    const json = (await res.json()) as { error: { code: string } };
    expect(json.error.code).toBe("dispatch_unavailable");
  });
});

describe("/admin surface sanity (asked alongside the dispatcher)", () => {
  it("renders /admin/login and redirects unauthenticated /admin/arul/wallpapers to /admin/login", async () => {
    const { env } = makeEnv();

    const login = await worker.fetch(
      new Request("https://api.hsrutility.com/admin/login"),
      env,
      execCtx,
    );
    expect(login.status).toBe(200);
    expect(await login.text()).toContain("Sign in");

    const guarded = await worker.fetch(
      new Request("https://api.hsrutility.com/admin/arul/wallpapers"),
      env,
      execCtx,
    );
    expect(guarded.status).toBe(302);
    expect(guarded.headers.get("location")).toBe("/admin/login");
  });
});
