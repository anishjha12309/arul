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

  it("pakiza STATIC wallpapers never touch the thumb pipeline (posters have no derived thumb)", async () => {
    stubFetch(200);
    const { env, pakizaR2 } = makeEnv({
      pakizaRows: [{ full_key: "wallpapers/posters/poster.jpg" }],
    });

    const app = makeWallpapersApp(PAKIZA);
    await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/delete", { method: "POST" }),
      env,
      execCtx,
    );
    // The poster itself goes; no thumbs/ key is derived or deleted for statics.
    expect(pakizaR2.calls.delete).toContain("wallpapers/posters/poster.jpg");
    expect(pakizaR2.calls.delete.some((k: string) => k.startsWith("thumbs/"))).toBe(false);
  });

  it("delete of a live wallpaper also removes its derived thumb after rebuild", async () => {
    stubFetch(200);
    const { env, arulR2 } = makeEnv({ arulRows: [{ full_key: "wallpapers/amman/clip.mp4" }] });

    const app = makeWallpapersApp(ARUL);
    await app.fetch(
      new Request("https://hsr-cms.example.com/wp-1/delete", { method: "POST" }),
      env,
      execCtx,
    );
    expect(arulR2.calls.delete).toContain("wallpapers/amman/clip.mp4");
    expect(arulR2.calls.delete).toContain("thumbs/amman/clip.jpg");
  });
});

describe("bulk actions", () => {
  const ID_A = "1c237f37-e962-470b-99a8-9be57c080f88";
  const ID_B = "303dc99d-4018-49bb-8506-b160673c22f5";

  it("bulk unpublish updates the set + bumps content_version in ONE txn, ONE rebuild", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/bulk", {
        method: "POST",
        body: new URLSearchParams({ bulk_action: "unpublish", ids: `${ID_A},${ID_B}` }),
      }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("2 wallpapers unpublished");
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("UPDATE wallpapers SET is_published =");
    expect(text).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1); // one rebuild for the whole batch
  });

  it("bulk delete drops rows, then removes media + derived thumbs after a confirmed rebuild", async () => {
    stubFetch(200);
    const { env, arulR2 } = makeEnv({
      arulRows: [{ full_key: "wallpapers/sivan/a.jpg" }, { full_key: "wallpapers/sivan/b.mp4" }],
    });

    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/bulk", {
        method: "POST",
        body: new URLSearchParams({ bulk_action: "delete", ids: `${ID_A},${ID_B}` }),
      }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(arulR2.calls.delete).toContain("wallpapers/sivan/a.jpg");
    expect(arulR2.calls.delete).toContain("wallpapers/sivan/b.mp4");
    // live item's derived thumb goes too; the static's mapped thumb key delete is a no-op
    expect(arulR2.calls.delete).toContain("thumbs/sivan/b.jpg");
  });

  it("rejects malformed ids and unknown actions", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeWallpapersApp(ARUL);

    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/bulk", {
        method: "POST",
        body: new URLSearchParams({ bulk_action: "delete", ids: "1; DROP TABLE wallpapers" }),
      }),
      env,
      execCtx,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("err=");
    expect(arulSql.beginCalls).toBe(0);
  });
});

describe("batch create (items_json)", () => {
  it("inserts N rows with numbered titles in ONE txn + ONE rebuild", async () => {
    const fetchFn = stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });

    const items = [
      { key: "wallpapers/murugan/u1.jpg", mime: "image/jpeg", id: "1c237f37-e962-470b-99a8-9be57c080f88" },
      { key: "wallpapers/murugan/u2.mp4", mime: "video/mp4", id: "303dc99d-4018-49bb-8506-b160673c22f5" },
    ];
    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/", {
        method: "POST",
        body: new URLSearchParams({
          title: "Murugan",
          category: "murugan",
          items_json: JSON.stringify(items),
          is_published: "on",
        }),
      }),
      env,
      execCtx,
    );

    expect(res.status).toBe(302);
    expect(decodeURIComponent(res.headers.get("location") ?? "")).toContain("2 wallpapers created");
    expect(arulSql.beginCalls).toBe(1);
    const text = capturedSqlText(arulSql);
    expect(text).toContain("INSERT INTO wallpapers");
    expect(text).toContain("content_version = content_version + 1");
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("invalid batch payloads never reach the DB", async () => {
    stubFetch(200);
    const { env, arulSql } = makeEnv({ arulRows: [] });
    const app = makeWallpapersApp(ARUL);
    const res = await app.fetch(
      new Request("https://hsr-cms.example.com/", {
        method: "POST",
        body: new URLSearchParams({
          title: "X",
          category: "murugan",
          items_json: JSON.stringify([{ key: "../../etc", mime: "image/jpeg", id: "nope" }]),
        }),
      }),
      env,
      execCtx,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toContain("err=");
    expect(arulSql.beginCalls).toBe(0);
  });
});
