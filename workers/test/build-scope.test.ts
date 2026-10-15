/**
 * buildScope — the row shaping every installed app parses: the page a phone drains before first paint.
 *
 * A bigint shipped as a string, a leaked private column, a hole in feed_rank or a missing empty page
 * each broke (or would break) every install at once, so they are pinned against the REAL function.
 */

import { describe, it, expect, vi } from "vitest";
import { makeEnv } from "./_ctx.js";

// buildScope takes its sql directly; only the whole-build tests reach getDb -> they inject env._testSql
vi.mock("../src/lib/db.js", () => ({
  getDb: (env: { _testSql: unknown }) => env._testSql,
}));

import { buildScope, buildCatalog, refreshPopularityOrder } from "../src/cron/build-catalog.js";

function makeR2(existing: string[] = []) {
  const store = new Map<string, unknown>(existing.map((k) => [k, {}]));
  const cache = new Map<string, string | undefined>();
  const bucket = {
    get: vi.fn(async (key: string) =>
      store.has(key) ? { text: async () => JSON.stringify(store.get(key)) } : null,
    ),
    put: vi.fn(async (key: string, value: string, opts?: R2PutOptions) => {
      store.set(key, JSON.parse(value));
      cache.set(key, (opts?.httpMetadata as R2HTTPMetadata | undefined)?.cacheControl);
      return {} as R2Object;
    }),
    list: vi.fn(async (opts?: R2ListOptions) => ({
      objects: [...store.keys()].filter((k) => k.startsWith(opts?.prefix ?? "")).map((key) => ({ key })),
      truncated: false,
    })),
    delete: vi.fn(async (key: string) => {
      store.delete(key);
    }),
  } as unknown as R2Bucket;
  return { bucket, store, cache };
}

function sqlReturning(rows: Record<string, unknown>[]) {
  return vi.fn(async () => rows) as unknown as Parameters<typeof buildScope>[0];
}

const status = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  title: id,
  category: "murugan",
  full_key: `statuses/murugan/${id}.mp4`,
  mime: "video/mp4",
  duration_ms: 24000,
  width: 1024,
  height: 1824,
  bytes: "8000000",
  is_published: true,
  feed_rank: null,
  share_count: "3",
  download_count: "4",
  published_at: "2026-10-01T00:00:00Z",
  renewed_at: null,
  pre_renew_published_at: null,
  created_at: "2026-10-01T00:00:00Z",
  ...extra,
});

type Page = { items: Record<string, unknown>[]; total: number; total_pages: number; has_more: boolean };

const wallpaper = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  title: id,
  category: "murugan",
  type: "static",
  full_key: `wallpapers/${id}.webp`,
  mime: "image/webp",
  apply_count: "5",
  apply_score: 1.2,
  scored_at: "2026-09-01T00:00:00Z",
  pre_renew_published_at: null,
  width: 1080,
  height: 1920,
  bytes: 123,
  tags: "{a,b}",
  ...extra,
});

describe("buildScope", () => {
  it("a zero-row scope still writes a valid empty all_1.json", async () => {
    const { bucket, store } = makeR2();
    const r = await buildScope(sqlReturning([]), bucket, "wallpapers");
    expect(r.pages).toBe(1);
    const page = store.get("catalog/wallpapers/all_1.json") as Page;
    expect(page.items).toEqual([]);
    expect(page.total).toBe(0);
    expect(page.has_more).toBe(false);
  });

  it("ships counters as numbers, tags as a list, and no private or retired columns", async () => {
    const { bucket, store } = makeR2();
    await buildScope(sqlReturning([wallpaper("w1")]), bucket, "wallpapers");
    const item = (store.get("catalog/wallpapers/all_1.json") as Page).items[0];
    expect(item["apply_count"]).toBe(5);
    expect(item["tags"]).toEqual(["a", "b"]);
    for (const k of [
      "apply_score",
      "scored_at",
      "pre_renew_published_at",
      "width",
      "height",
      "bytes",
      "mime",
    ]) {
      expect(item).not.toHaveProperty(k);
    }
    expect(item["category"]).toBe("murugan");
  });

  it("skips invalid rows and keeps feed_rank contiguous in the served order", async () => {
    const { bucket, store } = makeR2();
    const r = await buildScope(
      sqlReturning([
        wallpaper("a"),
        wallpaper("bad", { full_key: null }),
        wallpaper("live-bad", { type: "live", mime: "image/webp" }),
        wallpaper("b"),
      ]),
      bucket,
      "wallpapers",
    );
    expect(r.skipped).toBe(2);
    const items = (store.get("catalog/wallpapers/all_1.json") as Page).items;
    expect(items.map((i) => i["id"])).toEqual(["a", "b"]);
    const ranks = items.map((i) => i["feed_rank"] as number);
    expect(ranks[0]).toBeLessThan(ranks[1]);
  });

  it("ringtones keep mime and drop full_key; set_count becomes a number", async () => {
    const { bucket, store } = makeR2();
    await buildScope(
      sqlReturning([
        {
          id: "r1",
          title: "r1",
          category: "sivan",
          audio_key: "r/r1.mp3",
          mime: "audio/mpeg",
          set_count: "9",
          full_key: "x",
          set_score: 2,
        },
        { id: "r2", title: "r2", category: "sivan", audio_key: null },
      ]),
      bucket,
      "ringtones",
    );
    const items = (store.get("catalog/ringtones/all_1.json") as Page).items;
    expect(items).toHaveLength(1);
    expect(items[0]["mime"]).toBe("audio/mpeg");
    expect(items[0]["set_count"]).toBe(9);
    expect(items[0]).not.toHaveProperty("full_key");
    expect(items[0]).not.toHaveProperty("set_score");
  });

  it("paginates at 200 and deletes a page number the scope no longer produces", async () => {
    const { bucket, store } = makeR2(["catalog/wallpapers/all_3.json"]);
    const rows = Array.from({ length: 201 }, (_, i) => wallpaper(`w${i}`));
    const r = await buildScope(sqlReturning(rows), bucket, "wallpapers");
    expect(r.pages).toBe(2);
    expect((store.get("catalog/wallpapers/all_1.json") as Page).has_more).toBe(true);
    expect((store.get("catalog/wallpapers/all_2.json") as Page).items).toHaveLength(1);
    expect(store.has("catalog/wallpapers/all_3.json")).toBe(false);
    expect(r.deleted).toBe(1);
  });

  it("an unknown scope throws rather than writing anything", async () => {
    const { bucket, store } = makeR2();
    await expect(buildScope(sqlReturning([]), bucket, "sounds")).rejects.toThrow(/unknown scope/);
    expect(store.size).toBe(0);
  });

  // ── statuses: a third scope no fielded build fetches ──────────────────────

  it("statuses ship only the reel's fields under catalog/statuses/, drawn from a stable id order", async () => {
    const { bucket, store } = makeR2();
    const sql = vi.fn(async (..._args: unknown[]) => [status("s1"), status("s2")]);
    // Equal weights + one fixed draw -> equal keys -> the stable sort keeps the SQL's order
    const r = await buildScope(sql as never, bucket, "statuses", () => 0.5);
    expect(r).toMatchObject({ pages: 1, items: 2, skipped: 0 });
    const text = (sql.mock.calls[0]![0] as string[]).join("?");
    expect(text).toMatch(/FROM statuses/);
    expect(text).toMatch(/ORDER BY id ASC/);
    expect(text).not.toMatch(/feed_rank/);
    const items = (store.get("catalog/statuses/all_1.json") as Page).items;
    expect(items.map((i) => i["id"])).toEqual(["s1", "s2"]);
    expect(Object.keys(items[0]!).sort()).toEqual(
      [
        "category",
        "created_at",
        "duration_ms",
        "feed_rank",
        "full_key",
        "height",
        "id",
        "is_published",
        "published_at",
        "renewed_at",
        "title",
        "width",
      ].sort(),
    );
    // The card is sized from the clip's own shape before its first frame -> the page carries it
    expect(items[0]).toMatchObject({ width: 1024, height: 1824 });
    expect(items[0]!["feed_rank"]).toBeLessThan(items[1]!["feed_rank"] as number);
  });

  it("statuses ignore a stale CMS pin: the draw alone decides the order, renumbered 10, 20, 30", async () => {
    const { bucket, store } = makeR2();
    const draws = [0.9, 0.1, 0.5]; // log(1 - u) -> 0.1 draws highest, then 0.5, then 0.9
    let i = 0;
    await buildScope(
      sqlReturning([status("pinned", { feed_rank: 10 }), status("b"), status("c")]),
      bucket,
      "statuses",
      () => draws[i++]!,
      new Date("2026-12-01T00:00:00Z"),
    );
    const items = (store.get("catalog/statuses/all_1.json") as Page).items;
    expect(items.map((x) => x["id"])).toEqual(["b", "c", "pinned"]);
    expect(items.map((x) => x["feed_rank"])).toEqual([10, 20, 30]);
  });

  it("statuses lean to used and fresh clips without ever fixing the order", async () => {
    const now = new Date("2026-10-14T12:00:00Z");
    const rows = [
      status("old", { share_count: "0", download_count: "0", published_at: "2026-01-01T00:00:00Z" }),
      status("busy", { share_count: "900", download_count: "100", published_at: "2026-01-01T00:00:00Z" }),
      status("fresh", { share_count: "0", download_count: "0", published_at: "2026-10-14T11:00:00Z" }),
      status("renewed", {
        share_count: "0",
        download_count: "0",
        published_at: "2026-10-14T11:00:00Z",
        pre_renew_published_at: "2026-01-01T00:00:00Z",
        renewed_at: "2026-10-14T11:00:00Z",
      }),
    ];
    // A seeded LCG -> the same 4,000 draws every run, so the test cannot flake
    let seed = 42;
    const random = () => {
      seed = (seed * 1664525 + 1013904223) % 2 ** 32;
      return seed / 2 ** 32;
    };
    const firsts = new Map<string, number>();
    for (let run = 0; run < 1000; run++) {
      const { bucket, store } = makeR2();
      await buildScope(sqlReturning(rows), bucket, "statuses", random, now);
      const top = (store.get("catalog/statuses/all_1.json") as Page).items[0]!["id"] as string;
      firsts.set(top, (firsts.get(top) ?? 0) + 1);
    }
    // Weights ~1 : 4 : 4 : 4 -> "old" leads ~1 in 13 runs, never 0 and never most
    expect(firsts.get("old") ?? 0).toBeGreaterThan(30);
    expect(firsts.get("old") ?? 0).toBeLessThan(150);
    for (const id of ["busy", "fresh", "renewed"]) expect(firsts.get(id) ?? 0).toBeGreaterThan(200);
  });

  it("statuses ship as ONE short-cached page however many there are", async () => {
    const { bucket, store, cache } = makeR2(["catalog/statuses/all_2.json"]);
    const rows = Array.from({ length: 450 }, (_, i) => status(`s${i}`));
    const r = await buildScope(sqlReturning(rows), bucket, "statuses");
    expect(r).toMatchObject({ pages: 1, items: 450, deleted: 1 });
    const page = store.get("catalog/statuses/all_1.json") as Page & { per_page: number };
    expect(page).toMatchObject({ total: 450, total_pages: 1, has_more: false, per_page: 450 });
    expect(new Set(page.items.map((x) => x["id"])).size).toBe(450);
    expect(store.has("catalog/statuses/all_2.json")).toBe(false);
    expect(cache.get("catalog/statuses/all_1.json")).toBe("public, max-age=600, stale-while-revalidate=600");
  });

  it("statuses skip a row with no full_key or a non-mp4 mime", async () => {
    const { bucket, store } = makeR2();
    const r = await buildScope(
      sqlReturning([status("a"), status("nokey", { full_key: null }), status("jpg", { mime: "image/jpeg" })]),
      bucket,
      "statuses",
    );
    expect(r.skipped).toBe(2);
    expect((store.get("catalog/statuses/all_1.json") as Page).items.map((i) => i["id"])).toEqual(["a"]);
  });

  // postgres.js hands jsonb back parsed -> the page must carry the slot as an object, never a string
  it("statuses carry photo_slot through as the row holds it: an object, or null for a clip with no frame", async () => {
    const { bucket, store } = makeR2();
    const slot = { left: 0.3583, top: 0.6865, size: 0.2917, shape: "soft_circle" };
    await buildScope(
      sqlReturning([
        status("framed", { width: 768, height: 1152, category: "kannada", photo_slot: slot }),
        status("bare", { photo_slot: null }),
      ]),
      bucket,
      "statuses",
      () => 0.5,
    );
    const page = store.get("catalog/statuses/all_1.json") as Page;
    const byId = Object.fromEntries(page.items.map((i) => [i["id"], i]));
    expect(byId["framed"]).toMatchObject({ photo_slot: slot, width: 768, height: 1152, category: "kannada" });
    expect(byId["bare"]).toHaveProperty("photo_slot", null);
    expect(JSON.stringify(page)).toContain(
      '"photo_slot":{"left":0.3583,"top":0.6865,"size":0.2917,"shape":"soft_circle"}',
    );
  });

  // The import stages a library as drafts -> only the SELECT keeps them out of every installed app's feed
  it("a draft status (is_published=false) never reaches the page", async () => {
    const { bucket, store } = makeR2();
    const rows = [
      status("live"),
      status("draft", {
        is_published: false,
        published_at: null,
        photo_slot: { left: 0, top: 0, size: 1, shape: "pin" },
      }),
    ];
    // Postgres stand-in: honours the published filter only if the build's SQL asks for it
    const sql = vi.fn(async (strings: TemplateStringsArray) =>
      /WHERE is_published = true/.test(strings.join("?")) ? rows.filter((r) => r.is_published) : rows,
    );
    const r = await buildScope(sql as never, bucket, "statuses");
    expect(r).toMatchObject({ items: 1, skipped: 0 });
    expect((store.get("catalog/statuses/all_1.json") as Page).items.map((i) => i["id"])).toEqual(["live"]);
  });

  it("a missing statuses table (42P01) writes a valid empty page instead of failing the scope", async () => {
    const { bucket, store } = makeR2();
    const missing = Object.assign(new Error('relation "statuses" does not exist'), { code: "42P01" });
    const r = await buildScope(vi.fn(async () => Promise.reject(missing)) as never, bucket, "statuses");
    expect(r).toMatchObject({ pages: 1, items: 0, skipped: 0 });
    const page = store.get("catalog/statuses/all_1.json") as Page;
    expect(page.items).toEqual([]);
    expect(page.total).toBe(0);
  });

  it("any OTHER statuses error still fails the scope", async () => {
    const { bucket } = makeR2();
    await expect(
      buildScope(vi.fn(async () => Promise.reject(new Error("boom"))) as never, bucket, "statuses"),
    ).rejects.toThrow("boom");
  });

  // The pages fielded builds parse, pinned byte for byte -> adding a scope must not move a single key
  it("wallpaper and ringtone pages are byte-identical", async () => {
    const { bucket, store } = makeR2();
    await buildScope(
      sqlReturning([
        wallpaper("w1", {
          feed_rank: 7,
          published_at: "p",
          renewed_at: null,
          created_at: "c",
          sort_order: 0,
        }),
      ]),
      bucket,
      "wallpapers",
    );
    await buildScope(
      sqlReturning([
        {
          id: "r1",
          title: "r1",
          category: "sivan",
          tags: "{}",
          audio_key: "ringtones/sivan/r1.mp3",
          cover_key: null,
          mime: "audio/mpeg",
          duration_ms: 30000,
          bytes: 99,
          set_count: "2",
          set_score: 1,
          feed_rank: null,
          published_at: "p",
          renewed_at: "r",
          pre_renew_published_at: "q",
          created_at: "c",
        },
      ]),
      bucket,
      "ringtones",
    );
    expect(JSON.stringify(store.get("catalog/wallpapers/all_1.json"))).toBe(
      '{"page":1,"per_page":200,"total":1,"total_pages":1,"has_more":false,"items":[{"id":"w1","title":"w1","category":"murugan","type":"static","full_key":"wallpapers/w1.webp","apply_count":5,"tags":["a","b"],"feed_rank":10,"published_at":"p","renewed_at":null,"created_at":"c","sort_order":0}]}',
    );
    expect(JSON.stringify(store.get("catalog/ringtones/all_1.json"))).toBe(
      '{"page":1,"per_page":200,"total":1,"total_pages":1,"has_more":false,"items":[{"id":"r1","title":"r1","category":"sivan","tags":[],"audio_key":"ringtones/sivan/r1.mp3","cover_key":null,"mime":"audio/mpeg","set_count":2,"feed_rank":10,"published_at":"p","renewed_at":"r","created_at":"c"}]}',
    );
  });
});

// ── The whole build: the statuses scope can never freeze the other two ───────
// version.json commits only when EVERY scope built -> a statuses error would stop new wallpapers reaching every build
describe("buildCatalog with the statuses scope", () => {
  function routedSql(statuses: () => Promise<unknown[]>, categories: unknown[] = []) {
    const fn = vi.fn((strings: TemplateStringsArray | string[]) => {
      const text = Array.isArray(strings) ? strings.join("?") : String(strings);
      if (/FROM app_config/.test(text)) {
        return Promise.resolve([
          {
            content_version: "42",
            prices: {},
            support_email: null,
            policy_urls: {},
            feature_flags: {},
            min_supported_version: null,
          },
        ]);
      }
      if (/FROM categories/.test(text)) return Promise.resolve(categories);
      if (/FROM wallpapers/.test(text)) return Promise.resolve([wallpaper("w1")]);
      if (/FROM ringtones/.test(text)) {
        return Promise.resolve([{ id: "r1", title: "r1", category: "sivan", audio_key: "r/r1.mp3" }]);
      }
      if (/FROM statuses/.test(text)) return statuses();
      return Promise.resolve([]);
    });
    return Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  }

  async function runBuild(sql: unknown, builtVersion?: string) {
    const { bucket, store, cache } = makeR2();
    const env = makeEnv({ R2: bucket });
    (env as unknown as { _testSql: unknown })._testSql = sql;
    if (builtVersion !== undefined) {
      for (const s of ["wallpapers", "ringtones", "statuses"])
        await env.KV.put(`catalog_version:${s}`, builtVersion);
    }
    const results = await buildCatalog(env, null);
    return { results, store, cache };
  }

  it("an unchanged catalog still reshuffles statuses, reported apart so the canonical sweep waits", async () => {
    const { results, store, cache } = await runBuild(
      routedSql(async () => [status("s1"), status("s2")]),
      "42",
    );
    expect(results["wallpapers"]).toEqual({ skipped: "no_change" });
    expect(results["ringtones"]).toEqual({ skipped: "no_change" });
    expect(results["statuses"]).toEqual({ reshuffled: { pages: 1, items: 2, skipped: 0, deleted: 0 } });
    // index.ts sweeps only when some result carries "pages" -> a reshuffle alone must not
    expect(Object.values(results).some((r) => r && typeof r === "object" && "pages" in r)).toBe(false);
    expect((store.get("catalog/statuses/all_1.json") as Page).items).toHaveLength(2);
    expect(store.has("catalog/wallpapers/all_1.json")).toBe(false);
    expect(cache.get("catalog/wallpapers/all_1.json")).toBeUndefined();
    expect((store.get("catalog/version.json") as { content_version: string }).content_version).toBe("42");
  });

  it("a failed reshuffle is a scope error, so version.json is not rewritten over it", async () => {
    const { results, store } = await runBuild(
      routedSql(() => Promise.reject(new Error("boom"))),
      "42",
    );
    expect(results["statuses"]).toMatchObject({ error: expect.stringContaining("boom") });
    expect(store.has("catalog/version.json")).toBe(false);
  });

  it("a missing statuses table builds an empty scope and still commits version.json", async () => {
    const missing = Object.assign(new Error('relation "statuses" does not exist'), { code: "42P01" });
    const { results, store } = await runBuild(routedSql(() => Promise.reject(missing)));
    expect(results["statuses"]).toEqual({ pages: 1, items: 0, skipped: 0, deleted: 0 });
    expect(results["wallpapers"]).toMatchObject({ pages: 1, items: 1 });
    expect(results["ringtones"]).toMatchObject({ pages: 1, items: 1 });
    expect((store.get("catalog/version.json") as { content_version: string }).content_version).toBe("42");
    expect((store.get("catalog/statuses/all_1.json") as Page).items).toEqual([]);
  });

  it("status categories order under their own key and never reach the wallpaper chip order", async () => {
    const { store } = await runBuild(
      routedSql(
        async () => [],
        [
          { kind: "status", slug: "amman" },
          { kind: "wallpaper", slug: "murugan" },
        ],
      ),
    );
    const cfg = store.get("catalog/app_config.json") as { category_order: Record<string, string[]> };
    expect(cfg.category_order).toEqual({ statuses: ["amman"], wallpapers: ["murugan"] });
  });
});

// The nightly bump compares one grand total -> status uses count, and a missing table must not stop the bump
describe("refreshPopularityOrder with statuses", () => {
  function sqlWith(statuses: () => Promise<unknown[]>) {
    const calls: string[] = [];
    const fn = vi.fn((strings: string[]) => {
      const text = strings.join("?");
      calls.push(text);
      if (/FROM statuses/.test(text)) return statuses();
      if (/FROM wallpapers/.test(text)) return Promise.resolve([{ total: "10" }]);
      return Promise.resolve([]);
    });
    return { sql: Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) }), calls };
  }

  async function refresh(sql: unknown) {
    const env = makeEnv();
    (env as unknown as { _testSql: unknown })._testSql = sql;
    return refreshPopularityOrder(env);
  }

  it("adds share + download uses into the total", async () => {
    const { sql, calls } = sqlWith(async () => [{ total: "5" }]);
    expect(await refresh(sql)).toEqual({ bumped: true, total: 15 });
    expect(calls.some((t) => /UPDATE app_config SET content_version = content_version \+ 1/.test(t))).toBe(
      true,
    );
  });

  it("a missing statuses table (42P01) still bumps on the wallpaper and ringtone total", async () => {
    const missing = Object.assign(new Error('relation "statuses" does not exist'), { code: "42P01" });
    const { sql } = sqlWith(() => Promise.reject(missing));
    expect(await refresh(sql)).toEqual({ bumped: true, total: 10 });
  });
});
