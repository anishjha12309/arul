/**
 * Design-preview harness (NOT part of the normal suite). Renders full pages
 * to static HTML files under cms/.preview/ so they can be opened directly in
 * a browser / screenshotted, using the same mocks as the real page tests.
 *
 * Skipped unless PREVIEW=1 is set:
 *   cd cms && PREVIEW=1 npx vitest run test/preview.test.ts
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { Hono } from "hono";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
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
import { handleLoginPage } from "../src/pages/login.js";
import { PAKIZA, ARUL } from "../src/registry.js";

const RUN = process.env.PREVIEW ? it : it.skip;

const OUT_DIR = join(__dirname, "..", ".preview");

function save(name: string, html: string) {
  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(join(OUT_DIR, `${name}.html`), html, "utf8");
}

const get = (app: Hono<{ Bindings: Env }>, env: Env, path = "/") =>
  app.fetch(new Request(`https://hsr-cms.example.com${path}`), env, execCtx);

// ── Real Arul CDN keys (from arul-import-result.json) — mixed static/live ──
const ARUL_KEYS: { key: string; cat: string; live: boolean }[] = [
  { key: "wallpapers/sivan/1c237f37-e962-470b-99a8-9be57c080f88.mp4", cat: "sivan", live: true },
  { key: "wallpapers/murugan/303dc99d-4018-49bb-8506-b160673c22f5.mp4", cat: "murugan", live: true },
  { key: "wallpapers/murugan/b8a67c48-64e4-4d29-9b22-b5af7d9842e9.jpg", cat: "murugan", live: false },
  { key: "wallpapers/perumal/0603d1fc-5fa6-44aa-a70d-f2d0f8da8882.jpg", cat: "perumal", live: false },
  { key: "wallpapers/murugan/daa48e57-d8ce-452e-8fb6-411c3a9691ff.jpg", cat: "murugan", live: false },
  { key: "wallpapers/ayyappan/6c8a51de-4841-43e8-a89e-055914151b72.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/murugan/0fbfe29d-2d61-43f0-82b9-de47a09f1978.mp4", cat: "murugan", live: true },
  { key: "wallpapers/amman/c7efa3a2-25d1-4e55-8a2d-884bb0750cbe.mp4", cat: "amman", live: true },
  { key: "wallpapers/ayyappan/f1b48b16-91f7-471d-8a58-0c5241f6ea09.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/ayyappan/c5b73132-09ea-4bd7-b1d9-21dfb8354a7f.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/murugan/c57e0802-38a4-45b1-9c90-f4aa46694534.mp4", cat: "murugan", live: true },
  { key: "wallpapers/murugan/ae6d50db-ded8-4e50-81ae-6edf7f3ee1d4.mp4", cat: "murugan", live: true },
  { key: "wallpapers/murugan/b9069c2e-cf36-47d1-bd32-e0885d587336.mp4", cat: "murugan", live: true },
  { key: "wallpapers/sivan/e4bf8901-fc9b-43e1-be35-e869ee5be783.jpg", cat: "sivan", live: false },
  { key: "wallpapers/sivan/acb6e35a-521d-4a56-b46b-3184b484ce5c.mp4", cat: "sivan", live: true },
  { key: "wallpapers/sivan/da2c8cce-5f83-41c8-8a41-29c4f18df7a4.jpg", cat: "sivan", live: false },
  { key: "wallpapers/ayyappan/54a79df3-893a-4e3a-95c9-198c7d06eb82.jpg", cat: "ayyappan", live: false },
  { key: "wallpapers/ayyappan/ef472bad-0c0a-485b-af27-427cc76edfd0.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/ayyappan/609ba98c-b7d0-4010-9667-446db0e2475a.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/ayyappan/1797d7e4-8446-453b-b954-5d736046877d.jpg", cat: "ayyappan", live: false },
  { key: "wallpapers/ayyappan/11bbc67e-9106-4d50-a94f-e6f67919060e.mp4", cat: "ayyappan", live: true },
  { key: "wallpapers/ayyappan/0ba8e99b-bc31-48c1-86f7-48479d4a1c78.jpg", cat: "ayyappan", live: false },
  { key: "wallpapers/perumal/5547edad-3205-45c7-8863-db5ad52e8755.jpg", cat: "perumal", live: false },
  { key: "wallpapers/murugan/c74b9658-c5ac-44fe-832f-0c060560d177.jpg", cat: "murugan", live: false },
];
// One deliberately-broken thumbnail (404) to test the neutral-tile fallback.
ARUL_KEYS.push({ key: "wallpapers/temples/00000000-0000-0000-0000-000000000000.mp4", cat: "temples", live: true });
// One row with a VERY long title + long category to exercise truncation.
ARUL_KEYS.push({
  key: "wallpapers/sri-ranganathaswamy-temple-corridors/9c60e131-57e5-4b76-ac8a-ed3cf4b3ca9b.jpg",
  cat: "sri-ranganathaswamy-temple-corridors",
  live: false,
});

const TITLES = [
  "Lord Murugan at dawn", "Ayyappan swamy", "Amman golden light", "Perumal temple gopuram",
  "Sivan lingam close-up", "Temple bells at dusk", "Murugan vel", "Sabarimala peak",
  "Meenakshi amman", "Padmanabhaswamy", "Nataraja bronze", "Temple corridor",
  "Murugan peacock", "Ayyappan pilgrimage", "Amman kolam", "Perumal garuda",
  "Sivan trishul", "Temple oil lamps", "Murugan Palani", "Ayyappan 18 steps",
  "Amman flowers", "Perumal conch", "Sivan nandi", "Temple broken preview",
  "Broken thumb fallback", // index 24 — the deliberately-404 row
  "Sri Ranganathaswamy Temple thousand-pillared corridor at golden hour with oil lamps and devotees during Vaikunta Ekadasi festival",
];

function arulRow(i: number, k: { key: string; cat: string; live: boolean }) {
  const ext = k.key.split(".").pop();
  // Real R2 keys embed a real UUID filename — reuse it as the row id so the
  // ID column shows varied, realistic values instead of a repeated pattern.
  const idMatch = /([0-9a-f-]{36})\.[a-z0-9]+$/i.exec(k.key);
  return {
    id: idMatch?.[1] ?? `00000000-0000-4000-8000-${String(100000000000 + i).padStart(12, "0")}`,
    title: TITLES[i] ?? `Wallpaper ${i + 1}`,
    type: k.live ? "live" : "static",
    category: k.cat,
    full_key: k.key,
    mime: k.live ? "video/mp4" : ext === "png" ? "image/png" : "image/jpeg",
    is_published: i % 3 !== 0, // ~2/3 published, rest draft
    created: `2026-0${(i % 6) + 1}-${String((i % 27) + 1).padStart(2, "0")}`,
  };
}

// Varied realistic-looking UUIDs (fixed list — deterministic previews).
const PAKIZA_IDS = [
  "025dabba-1900-47c1-84f4-eca4ade2279",
  "7a3f9c12-5e88-4b1d-9a6c-3d0f8e2b1177",
  "b4e1d6a0-2c3f-4a9e-8d5b-6f1a9c7e4402",
  "e29a4c7b-8f0d-4e6a-b3c1-59d7a2f6e810",
  "1f6d8b3e-4a7c-4d2f-9e1b-8c5a3f0d6b29",
  "9c2e7a5d-1b4f-4c8e-a6d3-7f2b9e4c1a58",
  "3a8f1c6d-5e9b-4f2a-8c7d-1a6e3b9f5d02",
  "c7d4a9e2-6f1b-4a3d-9e8c-2b5f7a1d6c94",
  "5e1b8d3a-9c6f-4e2b-8a1d-6f3c9e5b2a71",
  "a2f6c9e1-3d8b-4c5a-9e2f-1b6d8a3c5e07",
  "d8b3e6a1-7c2f-4d9b-8e5a-3c1f6b9d2e48",
  "6a9c2f5e-1b8d-4a3c-9f6e-2d5b8a1c6f39",
];
const PAKIZA_KEYS = Array.from({ length: 12 }, (_, i) => ({
  key:
    i % 2 === 0
      ? `wallpapers/full/${PAKIZA_IDS[i]}.mp4`
      : `wallpapers/posters/${PAKIZA_IDS[i]}.jpg`,
  live: i % 2 === 0,
}));

function pakizaRow(i: number, k: { key: string; live: boolean }) {
  return {
    id: PAKIZA_IDS[i] ?? `10000000-0000-4000-8000-${String(200000000000 + i).padStart(12, "0")}`,
    title: `Pakiza wallpaper ${i + 1}`,
    type: k.live ? "live" : "static",
    full_key: k.key,
    mime: k.live ? "video/mp4" : "image/jpeg",
    is_published: i % 4 !== 0,
    created: `2026-0${(i % 6) + 1}-${String((i % 27) + 1).padStart(2, "0")}`,
  };
}

beforeEach(() => {
  stubFetch();
});

describe("preview harness", () => {
  RUN("renders login", async () => {
    const app = new Hono<{ Bindings: Env }>().get("/", handleLoginPage);
    const res = await app.fetch(new Request("https://hsr-cms.example.com/"), {} as Env, execCtx);
    save("login", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders dashboard", async () => {
    // dashboard.tsx runs TWO queries per app (stats row, then categories rows)
    // against the SAME mock handle, which always returns the same `rows` — so
    // give every row both shapes' keys, matched positionally by rows[0] (stats)
    // and the full array (categories).
    const arulSql = makeMockSql([
      { wp_total: 428, wp_pub: 401, pending: 5, version: 32, category: "amman", pub: "60", total: "70" },
      { category: "ayyappan", pub: "38", total: "45" },
      { category: "murugan", pub: "120", total: "130" },
      { category: "perumal", pub: "70", total: "78" },
      { category: "sivan", pub: "55", total: "60" },
      { category: "temples", pub: "58", total: "70" },
    ]);
    const pakizaSql = makeMockSql([
      { wp_total: 111, wp_pub: 98, rt_total: 51, rt_pub: 44, pending: 3, version: 228 },
    ]);
    const { env } = makeEnv({ arulSql, pakizaSql });
    const app = new Hono<{ Bindings: Env }>().get("/", handleDashboard);
    const res = await app.fetch(new Request("https://hsr-cms.example.com/"), env, execCtx);
    save("dashboard", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul wallpapers (mixed)", async () => {
    const arulRows = ARUL_KEYS.map((k, i) => arulRow(i, k));
    const { env } = makeEnv({ arulRows });
    const res = await get(makeWallpapersApp(ARUL), env);
    save("arul-wallpapers", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul wallpapers with a flash toast", async () => {
    const arulRows = ARUL_KEYS.slice(0, 6).map((k, i) => arulRow(i, k));
    const { env } = makeEnv({ arulRows });
    const res = await get(makeWallpapersApp(ARUL), env, "/?ok=Wallpaper%20created");
    save("arul-wallpapers-flash", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul edit-form fragment (modal body)", async () => {
    const arulRows = [
      {
        id: "9c60e131-57e5-4b76-ac8a-ed3cf4b3ca9b",
        title: "Lord Subramanya Swamy",
        type: "static",
        category: "murugan",
        full_key: "wallpapers/murugan/9c60e131-57e5-4b76-ac8a-ed3cf4b3ca9b.jpg",
        is_published: true,
      },
    ];
    const { env } = makeEnv({ arulRows });
    const res = await makeWallpapersApp(ARUL).fetch(
      new Request("https://hsr-cms.example.com/9c60e131-57e5-4b76-ac8a-ed3cf4b3ca9b/edit", {
        headers: { "HX-Request": "true" },
      }),
      env,
      execCtx,
    );
    save("arul-wallpaper-edit-fragment", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders pakiza wallpapers", async () => {
    const pakizaRows = PAKIZA_KEYS.map((k, i) => pakizaRow(i, k));
    const { env } = makeEnv({ pakizaRows });
    const res = await get(makeWallpapersApp(PAKIZA), env);
    save("pakiza-wallpapers", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders pakiza ringtones", async () => {
    const pakizaRows = Array.from({ length: 10 }, (_, i) => ({
      id: `20000000-0000-4000-8000-${String(300000000000 + i).padStart(12, "0")}`,
      title: `Azaan variant ${i + 1}`,
      audio_key: `ringtones/audio/${i}.mp3`,
      mime: "audio/mpeg",
      is_published: i % 3 !== 0,
    }));
    const { env } = makeEnv({ pakizaRows });
    const res = await get(makeRingtonesApp(PAKIZA), env);
    save("pakiza-ringtones", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul submissions (3 pending)", async () => {
    const arulRows = [
      { id: "s1", kind: "wallpaper", file_key: "user/u1/submissions/a.jpg", title: "Community Murugan", category: "murugan", status: "pending", rejection_reason: null, created_at: "2026-07-14" },
      { id: "s2", kind: "wallpaper", file_key: "user/u2/submissions/b.mp4", title: "Temple live clip", category: "temples", status: "pending", rejection_reason: null, created_at: "2026-07-15" },
      { id: "s3", kind: "wallpaper", file_key: "user/u3/submissions/c.jpg", title: null, category: null, status: "pending", rejection_reason: null, created_at: "2026-07-16" },
    ];
    const { env } = makeEnv({ arulRows });
    const res = await get(makeSubmissionsApp(ARUL), env);
    save("arul-submissions", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul submissions empty state", async () => {
    const { env } = makeEnv({ arulRows: [] });
    const res = await get(makeSubmissionsApp(ARUL), env);
    save("arul-submissions-empty", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul transfer", async () => {
    const arulSql = makeMockSql([
      { id: "1", title: "Amman gold", type: "static", category: "amman", full_key: ARUL_KEYS[2]!.key },
      { id: "2", title: "Amman flowers", type: "live", category: "amman", full_key: ARUL_KEYS[0]!.key },
      { id: "3", title: "Amman kolam", type: "static", category: "amman", full_key: ARUL_KEYS[4]!.key },
      { id: "4", title: "Amman light", type: "live", category: "amman", full_key: ARUL_KEYS[7]!.key },
      { id: "5", title: "Amman gold light", type: "static", category: "amman", full_key: ARUL_KEYS[16]!.key },
      { id: "6", title: "Amman evening", type: "live", category: "amman", full_key: ARUL_KEYS[5]!.key },
    ]);
    const { env } = makeEnv({ arulSql });
    const res = await get(makeTransferApp(ARUL), env, "/?source=amman");
    save("arul-transfer", await res.text());
    expect(res.status).toBe(200);
  });

  RUN("renders arul config", async () => {
    const arulRows = [
      {
        content_version: 32,
        prices: { trial_days: 3, monthly_inr: 149 },
        support_email: "support@hsrutility.com",
        policy_urls: { privacy: "https://arul.app/privacy", terms: "https://arul.app/terms" },
        feature_flags: { upload_enabled: true },
        min_supported_version: "1.0.0",
      },
    ];
    const { env } = makeEnv({ arulRows });
    const res = await get(makeConfigApp(ARUL), env);
    save("arul-config", await res.text());
    expect(res.status).toBe(200);
  });
});
