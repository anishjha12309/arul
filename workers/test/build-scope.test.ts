/**
 * buildScope — the row shaping every installed app parses: the page a phone drains before first paint.
 *
 * A bigint shipped as a string, a leaked private column, a hole in feed_rank or a missing empty page
 * each broke (or would break) every install at once, so they are pinned against the REAL function.
 */

import { describe, it, expect, vi } from "vitest";
import { buildScope } from "../src/cron/build-catalog.js";

function makeR2(existing: string[] = []) {
  const store = new Map<string, unknown>(existing.map((k) => [k, {}]));
  const bucket = {
    put: vi.fn(async (key: string, value: string) => {
      store.set(key, JSON.parse(value));
      return {} as R2Object;
    }),
    list: vi.fn(async (opts?: R2ListOptions) => ({
      objects: [...store.keys()]
        .filter((k) => k.startsWith(opts?.prefix ?? ""))
        .map((key) => ({ key })),
      truncated: false,
    })),
    delete: vi.fn(async (key: string) => {
      store.delete(key);
    }),
  } as unknown as R2Bucket;
  return { bucket, store };
}

function sqlReturning(rows: Record<string, unknown>[]) {
  return vi.fn(async () => rows) as unknown as Parameters<typeof buildScope>[0];
}

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
    for (const k of ["apply_score", "scored_at", "pre_renew_published_at", "width", "height", "bytes", "mime"]) {
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
        { id: "r1", title: "r1", category: "sivan", audio_key: "r/r1.mp3", mime: "audio/mpeg", set_count: "9", full_key: "x", set_score: 2 },
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
});
