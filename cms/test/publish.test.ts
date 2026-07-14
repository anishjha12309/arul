/**
 * Publish flow: every content mutation bumps app_config.content_version IN THE
 * SAME TRANSACTION as the row write, then fires the app Worker's
 * POST /internal/build-catalog with the per-app bearer secret. A failed
 * rebuild must NOT roll back the DB write — it surfaces a retry banner via the
 * redirect's err param instead.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { makeEnv, execCtx, stubFetch, capturedSqlText } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import { makeWallpapersApp } from "../src/pages/wallpapers.js";
import { ARUL, PAKIZA } from "../src/registry.js";

beforeEach(() => {
  vi.unstubAllGlobals();
});

describe("publish flow", () => {
  it("publish toggle bumps content_version inside the transaction and triggers the rebuild", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [{ full_key: "wallpapers/amman/x.jpg" }] });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/publish", { method: "POST" }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("ok=");
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("UPDATE wallpapers SET is_published = NOT is_published");
    expect(text).toContain("UPDATE app_config SET content_version = content_version + 1");
    // Rebuild fired once against Arul's API with Arul's secret.
    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [input, init] = fetchFn.mock.calls[0]! as [string, RequestInit];
    expect(String(input)).toBe("https://arul-api.twilight-smoke-d495.workers.dev/internal/build-catalog");
    expect((init.headers as Record<string, string>)["Authorization"]).toBe(
      "Bearer test-arul-catalog-secret",
    );
    expect(init.method).toBe("POST");
  });

  it("create bumps content_version in the same transaction (Pakiza)", async () => {
    stubFetch(200);
    const { env, pakizaSql } = makeEnv({ pakizaRows: [] });

    const app = makeWallpapersApp(PAKIZA);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/", {
        method: "POST",
        body: new URLSearchParams({
          title: "New one",
          key_main: "wallpapers/posters/abc.jpg",
          mime_main: "image/jpeg",
          id_main: "abc",
          is_published: "on",
        }),
      }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("ok=");
    expect(pakizaSql.beginCalls).toBe(1);
    const text = capturedSqlText(pakizaSql);
    expect(text).toContain("INSERT INTO wallpapers");
    expect(text).toContain("content_version = content_version + 1");
  });

  it("a failed rebuild keeps the DB write and surfaces a retry banner", async () => {
    const fetchFn = stubFetch(500); // app Worker rejects the rebuild
    const { env, arulSql } = makeEnv({ arulRows: [{ full_key: "wallpapers/amman/x.jpg" }] });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/publish", { method: "POST" }),
      env,
      execCtx,
    );

    // The transaction still ran (no rollback) …
    expect(arulSql.beginCalls).toBe(1);
    expect(capturedSqlText(arulSql)).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1);
    // … and the redirect carries the "rebuild failed, retry" banner.
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc).toContain("err=");
    expect(decodeURIComponent(loc)).toContain("rebuild failed");
  });

  it("a rebuild network error is also non-fatal", async () => {
    const fetchFn = vi.fn(async () => {
      throw new Error("network down");
    });
    vi.stubGlobal("fetch", fetchFn);
    const { env, arulSql } = makeEnv({ arulRows: [{ full_key: "wallpapers/amman/x.jpg" }] });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/publish", { method: "POST" }),
      env,
      execCtx,
    );

    expect(arulSql.beginCalls).toBe(1);
    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("rebuild failed");
  });

  it("delete removes the R2 object only AFTER a successful rebuild", async () => {
    stubFetch(500); // rebuild fails → bytes must be kept
    const { env, arulR2 } = makeEnv({ arulRows: [{ full_key: "wallpapers/amman/keep.jpg" }] });

    const app = makeWallpapersApp(ARUL);
    await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/delete", { method: "POST" }),
      env,
      execCtx,
    );
    expect(arulR2.calls.delete).not.toContain("wallpapers/amman/keep.jpg");
  });
});
