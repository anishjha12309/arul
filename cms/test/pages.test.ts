/**
 * One render test per major page, both apps — asserts each page returns 200
 * and shows its app-specific structure (Arul has category everywhere; Pakiza
 * keeps ringtones and no category column).
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { Hono } from "hono";
import { makeEnv, makeMockSql, execCtx, stubFetch } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import { makeWallpapersApp } from "../src/pages/wallpapers.js";
import { makeRingtonesApp } from "../src/pages/ringtones.js";
import { makeSubmissionsApp } from "../src/pages/submissions.js";
import { makeConfigApp } from "../src/pages/config.js";
import { makeTransferApp } from "../src/pages/transfer.js";
import { handleDashboard } from "../src/pages/dashboard.js";
import { PAKIZA, ARUL } from "../src/registry.js";

beforeEach(() => {
  stubFetch();
});

const get = (app: Hono<{ Bindings: Env }>, env: Env, path = "/") =>
  app.fetch(new Request(`https://hsr-cms.example.com${path}`), env, execCtx);

describe("page renders", () => {
  it("dashboard shows both apps' stats", async () => {
    const { env } = makeEnv({
      pakizaRows: [{ wp_total: 5, wp_pub: 4, rt_total: 9, rt_pub: 8, pending: 2, version: 11 }],
      arulRows: [{ wp_total: 428, wp_pub: 428, pending: 1, version: 6 }],
    });
    const app = new Hono<{ Bindings: Env }>().get("/", handleDashboard);
    const res = await get(app, env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Pakiza");
    expect(html).toContain("Arul");
    expect(html).toContain("Published ringtones"); // pakiza-only stat
    expect(html).toContain("428");
    expect(html).toContain("v11");
    expect(html).toContain("v6");
  });

  it("arul wallpapers list has a Category column; pakiza's does not", async () => {
    const arulRows = [
      { id: "1", title: "Murugan dawn", type: "static", category: "murugan", full_key: "wallpapers/murugan/a.jpg", is_published: true },
    ];
    const pakizaRows = [
      { id: "2", title: "Calligraphy", type: "static", full_key: "wallpapers/posters/b.jpg", is_published: true },
    ];
    const { env } = makeEnv({ arulRows, pakizaRows });

    const arulRes = await get(makeWallpapersApp(ARUL), env);
    expect(arulRes.status).toBe(200);
    const arulHtml = await arulRes.text();
    expect(arulHtml).toContain("Murugan dawn");
    expect(arulHtml).toContain("Category");
    expect(arulHtml).toContain("murugan");

    const pakRes = await get(makeWallpapersApp(PAKIZA), env);
    expect(pakRes.status).toBe(200);
    const pakHtml = await pakRes.text();
    expect(pakHtml).toContain("Calligraphy");
    expect(pakHtml).not.toContain(">Category <"); // no category column header
  });

  it("arul new-wallpaper form carries the category field and the arul presign URL", async () => {
    const { env } = makeEnv();
    const res = await get(makeWallpapersApp(ARUL), env, "/new");
    const html = await res.text();
    expect(html).toContain('name="category"');
    expect(html).toContain('data-presign="/admin/arul/media/upload-url"');
  });

  it("pakiza new-wallpaper form has NO category field and the pakiza presign URL", async () => {
    const { env } = makeEnv();
    const res = await get(makeWallpapersApp(PAKIZA), env, "/new");
    const html = await res.text();
    // (the shared upload SCRIPT contains a '[name="category"]' selector, so
    // assert on the rendered input element specifically)
    expect(html).not.toContain('<input name="category"');
    expect(html).toContain('data-presign="/admin/pakiza/media/upload-url"');
  });

  it("pakiza ringtones list renders", async () => {
    const { env } = makeEnv({
      pakizaRows: [{ id: "r1", title: "Azaan", audio_key: "ringtones/audio/r1.mp3", mime: "audio/mpeg", is_published: true }],
    });
    const res = await get(makeRingtonesApp(PAKIZA), env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Azaan");
    expect(html).toContain("ringtone");
  });

  it("submissions list renders with status tabs (arul)", async () => {
    const { env } = makeEnv({
      arulRows: [
        { id: "s1", kind: "wallpaper", file_key: "user/u/submissions/x.jpg", title: "Temple", category: "temples", status: "pending", rejection_reason: null, created_at: "2026-07-01" },
      ],
    });
    const res = await get(makeSubmissionsApp(ARUL), env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Temple");
    expect(html).toContain("pending");
    expect(html).toContain("rejected"); // tab strip
  });

  it("config editor renders prices/policy_urls/feature_flags (pakiza)", async () => {
    const { env } = makeEnv({
      pakizaRows: [
        {
          content_version: 12,
          prices: { monthly_inr: 199 },
          support_email: "support@hsrutility.com",
          policy_urls: {},
          feature_flags: {},
          min_supported_version: "1.0.0",
        },
      ],
    });
    const res = await get(makeConfigApp(PAKIZA), env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("content_version v12");
    expect(html).toContain("prices");
    expect(html).toContain("policy_urls");
    expect(html).toContain("feature_flags");
    expect(html).toContain("monthly_inr");
  });

  it("transfer page renders the source-category picker", async () => {
    const { env } = makeEnv({ arulRows: [{ category: "amman" }] });
    const res = await get(makeTransferApp(ARUL), env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Category transfer");
    expect(html).toContain("Source category");
    expect(html).toContain("amman");
  });

  it("transfer page with a source shows the checkbox grid + target datalist", async () => {
    // The SQL mock returns the same rows for every query; give rows that work
    // as both the categories query and the wallpapers query.
    const arulSql = makeMockSql([
      { id: "1", title: "Amman gold", type: "static", category: "amman", full_key: "wallpapers/amman/a.jpg" },
    ]);
    const { env } = makeEnv({ arulSql });
    const res = await get(makeTransferApp(ARUL), env, "/?source=amman");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('name="ids"');
    expect(html).toContain("Select all");
    expect(html).toContain('name="target"');
    expect(html).toContain("Move selected wallpapers");
  });
});
