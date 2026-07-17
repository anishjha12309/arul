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
import { makeArulRingtonesApp } from "../src/pages/ringtones-arul.js";
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
  it("dashboard shows both apps' stats, incl. Arul's ringtone count", async () => {
    const { env } = makeEnv({
      pakizaRows: [{ wp_total: 5, wp_pub: 4, rt_total: 9, rt_pub: 8, pending: 2, version: 11 }],
      arulRows: [{ wp_total: 428, wp_pub: 428, rt_total: 37, rt_pub: 36, pending: 1, version: 6 }],
    });
    const app = new Hono<{ Bindings: Env }>().get("/", handleDashboard);
    const res = await get(app, env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Pakiza");
    expect(html).toContain("Arul");
    // BOTH apps carry the ringtone stat now (Arul launched 2026-07-17)
    expect((html.match(/Published ringtones/g) ?? []).length).toBe(2);
    expect(html).toContain("428");
    expect(html).toContain("37 total"); // Arul ringtone total hint
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

  it("arul wallpapers list has a category filter select wired onto the Category column; pakiza's has none", async () => {
    const arulRows = [
      { id: "1", title: "Murugan dawn", type: "static", category: "murugan", full_key: "wallpapers/murugan/a.jpg", is_published: true },
      { id: "2", title: "Amman gold", type: "live", category: "amman", full_key: "wallpapers/amman/b.mp4", is_published: true },
      { id: "3", title: "Amman flowers", type: "static", category: "amman", full_key: "wallpapers/amman/c.jpg", is_published: false },
    ];
    const pakizaRows = [
      { id: "9", title: "Calligraphy", type: "static", full_key: "wallpapers/posters/b.jpg", is_published: true },
    ];
    const { env } = makeEnv({ arulRows, pakizaRows });

    const arulHtml = await (await get(makeWallpapersApp(ARUL), env)).text();
    // The filter select targets table column 4 — the same <td class="colcat">
    // index — via the same generic [data-filter] mechanism LIST_JS already
    // drives for type (col 3) and status, so no new client-side JS is needed.
    expect(arulHtml).toContain('data-filter="4" aria-label="Filter by category"');
    // Isolate the filter <select> itself (the page ALSO renders a <datalist>
    // of every known category on the create-form modal — a different element
    // that must not be confused with the list-filter options under test).
    const selMatch = /<select data-filter="4"[^>]*>[\s\S]*?<\/select>/.exec(arulHtml);
    expect(selMatch).not.toBeNull();
    const selHtml = selMatch![0];
    expect(selHtml).toContain(">All categories<");
    // One <option> per DISTINCT category actually present in the rows, capitalized.
    expect(selHtml).toContain('<option value="amman">Amman</option>');
    expect(selHtml).toContain('<option value="murugan">Murugan</option>');
    // A category absent from these rows must not appear as a filter option
    // (the create-form's datalist legitimately lists it — this select must not).
    expect(selHtml).not.toContain("sivan");
    // Static + live rows stay interleaved in ONE table — never split by type.
    expect((arulHtml.match(/<table/g) ?? []).length).toBe(1);
    expect(arulHtml).toContain("Murugan dawn"); // static
    expect(arulHtml).toContain("Amman gold"); // live, same table

    const pakHtml = await (await get(makeWallpapersApp(PAKIZA), env)).text();
    expect(pakHtml).not.toContain("Filter by category");
    expect(pakHtml).not.toContain("All categories");
  });

  it("live rows preview the mapped thumbs/ image for BOTH apps", async () => {
    const arulRows = [
      { id: "1", title: "Ayyappan live", type: "live", category: "ayyappan", full_key: "wallpapers/ayyappan/abc.mp4", is_published: true },
    ];
    const pakizaRows = [
      { id: "2", title: "Pakiza live", type: "live", full_key: "wallpapers/full/x.mp4", is_published: true },
    ];
    const { env } = makeEnv({ arulRows, pakizaRows });

    const arulHtml = await (await get(makeWallpapersApp(ARUL), env)).text();
    // live row maps full_key → thumbs/<cat>/<stem>.jpg and renders it as an <img>
    expect(arulHtml).toContain("thumbs/ayyappan/abc.jpg");
    expect(arulHtml).toContain("onerror="); // graceful fallback to ▶ when a thumb is absent

    const pakHtml = await (await get(makeWallpapersApp(PAKIZA), env)).text();
    // Pakiza live videos map wallpapers/full/<stem>.mp4 → thumbs/full/<stem>.jpg
    expect(pakHtml).toContain("thumbs/full/x.jpg");
    expect(pakHtml).toContain("onerror=");
  });

  it("pakiza static rows render their own image directly — no thumbs/ lookup", async () => {
    const pakizaRows = [
      { id: "3", title: "Poster", type: "static", full_key: "wallpapers/posters/p.jpg", is_published: true },
    ];
    const { env } = makeEnv({ pakizaRows });
    const html = await (await get(makeWallpapersApp(PAKIZA), env)).text();
    expect(html).toContain("wallpapers/posters/p.jpg"); // the poster IS the thumb
    expect(html).not.toContain("thumbs/"); // statics never derive a thumb key
  });

  it("wallpapers list carries id + created columns, bulk bar, and a grid view", async () => {
    const arulRows = [
      {
        id: "1c237f37-e962-470b-99a8-9be57c080f88",
        title: "Murugan dawn",
        type: "static",
        category: "murugan",
        full_key: "wallpapers/murugan/a.jpg",
        is_published: true,
        created: "2026-07-16",
      },
    ];
    const { env } = makeEnv({ arulRows });
    const html = await (await get(makeWallpapersApp(ARUL), env)).text();
    expect(html).toContain("1c237f37</span>"); // short id column
    expect(html).toContain("wallpapers/murugan/a.jpg"); // full key searchable (hidden span)
    expect(html).toContain("2026-07-16"); // created column
    expect(html).toContain("data-bulk-bar"); // bulk action bar
    expect(html).toContain('data-bulk-id="1c237f37-e962-470b-99a8-9be57c080f88"');
    expect(html).toContain("data-grid"); // grid view container
    expect(html).toContain('data-grid-id="1c237f37-e962-470b-99a8-9be57c080f88"');
    expect(html).toContain('action="/admin/arul/wallpapers/bulk"');
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

  it("pakiza ringtones page is UNCHANGED by the Arul launch — none of the Arul-only structure", async () => {
    const { env } = makeEnv({
      pakizaRows: [{ id: "r1", title: "Azaan", audio_key: "ringtones/audio/r1.mp3", mime: "audio/mpeg", is_published: true }],
    });
    const html = await (await get(makeRingtonesApp(PAKIZA), env)).text();
    // Pakiza's legacy page: no category input, no cover fields, no grid cards,
    // no bulk pill ELEMENT, and never the Arul-only data-rt-* uploader. (The
    // shared Layout scripts mention data-grid/data-bulk-bar as selectors on
    // every page, so assert on rendered elements, not raw substrings.)
    expect(html).not.toContain('<input name="category"');
    expect(html).not.toContain('class="pickgrid'); // no grid view markup
    expect(html).not.toContain('class="bulkbar"'); // no bulk pill element
    expect(html).not.toContain("data-rt-form");
    expect(html).not.toContain("data-rt-batch-form");
    expect(html).not.toContain("key_cover");
    expect(html).not.toContain("ringtone_cover");
    expect(html).toContain('data-kind="ringtone"'); // legacy shared uploader path
  });

  it("arul ringtones list renders covers, audio previews, category filter and keysearch", async () => {
    const arulRows = [
      {
        id: "1c237f37-e962-470b-99a8-9be57c080f88",
        title: "Om Namah",
        category: "sivan",
        audio_key: "ringtones/sivan/a.mp3",
        cover_key: "ringtones/covers/sivan/a.jpg",
        mime: "audio/mpeg",
        duration_ms: 94000,
        is_published: true,
        created: "2026-07-17",
      },
      {
        id: "303dc99d-4018-49bb-8506-b160673c22f5",
        title: "Bell Draftless",
        category: "temples",
        audio_key: "ringtones/temples/b.mp3",
        cover_key: null,
        mime: "audio/mpeg",
        duration_ms: null,
        is_published: true,
        created: "2026-07-17",
      },
    ];
    const { env } = makeEnv({ arulRows });
    const res = await get(makeArulRingtonesApp(ARUL), env);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Om Namah");
    expect(html).toContain("ringtones/covers/sivan/a.jpg"); // cover thumb
    expect(html).toContain("<audio"); // inline grid preview element
    expect(html).toContain('preload="none"'); // never pre-fetches audio bytes
    expect(html).toContain("ringtones/sivan/a.mp3"); // audio src + keysearch
    expect(html).toContain('data-filter="3" aria-label="Filter by category"');
    // Filter options = knownCategories UNION novel categories in rows.
    const selMatch = /<select data-filter="3"[^>]*>[\s\S]*?<\/select>/.exec(html);
    expect(selMatch![0]).toContain('<option value="amman">'); // known, no rows
    expect(selMatch![0]).toContain('<option value="sivan">'); // present in rows
    expect(html).toContain("1:34"); // duration formatted
    expect(html).toContain("1c237f37</span>"); // short id
    expect(html).toContain("data-bulk-bar"); // floating bulk pill
    expect(html).toContain('data-rt-bulk="category"'); // bulk category move
    expect(html).toContain('data-grid-id="1c237f37-e962-470b-99a8-9be57c080f88"');
    // Published row WITHOUT a cover: ♪ placeholder + warn badge, never an <img>
    // pointing at a null key.
    expect(html).toContain("no cover");
    expect(html).not.toContain('src="' + "https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev/null");
  });

  it("arul ringtones empty state shows the operable guidance card + batch CTA", async () => {
    const { env } = makeEnv({ arulRows: [] });
    const html = await (await get(makeArulRingtonesApp(ARUL), env)).text();
    expect(html).toContain("No ringtones yet");
    expect(html).toContain("batch-upload");
    expect(html).toContain("512×512");
    expect(html).toContain('data-dialog-target="rt-batch"');
    expect(html).toContain('data-dialog-target="rt-new"');
  });

  it("arul new-ringtone form requires BOTH audio and cover and posts to the arul presign", async () => {
    const { env } = makeEnv();
    const res = await get(makeArulRingtonesApp(ARUL), env, "/new");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('data-presign="/admin/arul/media/upload-url"');
    expect(html).toContain('data-slot="audio" data-required="1"');
    expect(html).toContain('data-slot="cover" data-required="1"');
    expect(html).toContain("audio/mpeg,audio/mp4,audio/aac,.mp3,.m4a,.aac");
    expect(html).toContain('name="category"');
    expect(html).toContain('name="duration_ms"');
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
