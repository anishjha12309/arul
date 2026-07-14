/**
 * App-registry routing isolation — the no-breakage guarantee.
 *
 * An /arul/* mutation must be provably unable to touch the Pakiza bindings
 * (DB handle, R2 bucket, API endpoint, catalog secret) and vice versa. Each
 * test runs a real mutation through the page sub-app and then asserts the
 * OTHER app's SQL handle recorded zero queries, its R2 bucket saw zero calls,
 * and the rebuild trigger hit only the mutated app's apiBase with only its
 * own secret.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { makeEnv, execCtx, stubFetch } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import { makeWallpapersApp } from "../src/pages/wallpapers.js";
import { PAKIZA, ARUL } from "../src/registry.js";

beforeEach(() => {
  vi.unstubAllGlobals();
});

function fetchCalls(fn: ReturnType<typeof stubFetch>): { url: string; auth: string }[] {
  return fn.mock.calls.map((call) => {
    const input = call[0] as Request | string;
    const init = call[1] as RequestInit | undefined;
    const url = typeof input === "string" ? input : input.url;
    const headers = (init?.headers ?? {}) as Record<string, string>;
    return { url, auth: headers["Authorization"] ?? "" };
  });
}

describe("routing isolation", () => {
  it("an /arul/* mutation touches only Arul's DB, bucket and API", async () => {
    const fetchFn = stubFetch();
    const rows = [{ full_key: "wallpapers/amman/x.jpg" }];
    const { env, pakizaSql, arulSql, pakizaR2 } = makeEnv({ arulRows: rows, pakizaRows: rows });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/publish", { method: "POST" }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302); // mutation completed → redirect
    // Arul's DB was used; Pakiza's handle recorded NOTHING.
    expect(arulSql.beginCalls).toBe(1);
    expect(arulSql.capturedArgs.length).toBeGreaterThan(0);
    expect(pakizaSql.beginCalls).toBe(0);
    expect(pakizaSql.capturedArgs.length).toBe(0);
    // Pakiza's bucket saw zero calls of any kind.
    expect(pakizaR2.calls.get.length + pakizaR2.calls.put.length + pakizaR2.calls.delete.length + pakizaR2.calls.head.length).toBe(0);
    // Exactly one rebuild call, to Arul's API with Arul's secret.
    const calls = fetchCalls(fetchFn);
    expect(calls.length).toBe(1);
    expect(calls[0]!.url).toBe("https://arul-api.twilight-smoke-d495.workers.dev/internal/build-catalog");
    expect(calls[0]!.auth).toBe("Bearer test-arul-catalog-secret");
  });

  it("a /pakiza/* mutation touches only Pakiza's DB, bucket and API", async () => {
    const fetchFn = stubFetch();
    const rows = [{ full_key: "wallpapers/posters/x.jpg" }];
    const { env, pakizaSql, arulSql, arulR2 } = makeEnv({ arulRows: rows, pakizaRows: rows });

    const app = makeWallpapersApp(PAKIZA);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/publish", { method: "POST" }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(pakizaSql.beginCalls).toBe(1);
    expect(pakizaSql.capturedArgs.length).toBeGreaterThan(0);
    expect(arulSql.beginCalls).toBe(0);
    expect(arulSql.capturedArgs.length).toBe(0);
    expect(arulR2.calls.get.length + arulR2.calls.put.length + arulR2.calls.delete.length + arulR2.calls.head.length).toBe(0);
    const calls = fetchCalls(fetchFn);
    expect(calls.length).toBe(1);
    expect(calls[0]!.url).toBe("https://api.hsrutility.com/internal/build-catalog");
    expect(calls[0]!.auth).toBe("Bearer test-pakiza-catalog-secret");
  });

  it("a delete on Arul removes bytes only from Arul's bucket", async () => {
    stubFetch();
    const rows = [{ full_key: "wallpapers/amman/gone.jpg" }];
    const { env, arulR2, pakizaR2 } = makeEnv({ arulRows: rows, pakizaRows: rows });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/delete", { method: "POST" }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(arulR2.calls.delete).toContain("wallpapers/amman/gone.jpg");
    expect(pakizaR2.calls.delete.length).toBe(0);
  });
});
