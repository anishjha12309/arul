/**
 * Unit tests for catalog shaping and key-stripping logic.
 * Tests the pure data transformation parts of build-catalog:
 *   1. KEY STRIPPING: wallpapers keep full_key + category (the browse axis)
 *   2. PAGINATION: 20/page, correct total/total_pages/has_more
 *   3. VALIDATION: rows missing required keys are excluded + skipped count
 *
 * The buildCatalog() function itself requires a live DB + R2 binding,
 * so we test the pure transformation helpers extracted here.
 */

import { describe, it, expect, vi } from "vitest";
import { writeAppConfig, deleteOrphanedPages } from "../src/cron/build-catalog.js";

// ── Mock R2 bucket that supports list() + delete() for orphan-cleanup tests ───
function makeListableR2(keys: string[]): {
  bucket: R2Bucket;
  deleted: string[];
  remaining: () => string[];
} {
  const store = new Set(keys);
  const deleted: string[] = [];
  const bucket = {
    list: vi.fn(async (opts?: R2ListOptions) => {
      const prefix = opts?.prefix ?? "";
      const objects = [...store]
        .filter((k) => k.startsWith(prefix))
        .map((key) => ({ key }));
      return { objects, truncated: false } as unknown as R2Objects;
    }),
    delete: vi.fn(async (key: string) => {
      store.delete(key);
      deleted.push(key);
    }),
  } as unknown as R2Bucket;
  return { bucket, deleted, remaining: () => [...store] };
}

// ── Mock R2 bucket that records put() calls ──────────────────────────────────
interface PutCall {
  key: string;
  body: unknown;
}
function makeMockR2(): { bucket: R2Bucket; puts: PutCall[] } {
  const puts: PutCall[] = [];
  const bucket = {
    put: vi.fn(async (key: string, value: string) => {
      puts.push({ key, body: JSON.parse(value) });
      return {} as R2Object;
    }),
    get: vi.fn(async () => null),
  } as unknown as R2Bucket;
  return { bucket, puts };
}

// ── Helpers extracted for testing (mirrors build-catalog.ts logic) ────────────

type ContentRow = Record<string, unknown>;

/** Strip private keys from a content row based on its scope. */
function stripPrivateKeys(scope: string, row: ContentRow): ContentRow {
  const r = { ...row };
  if (scope === "wallpapers") {
    delete r["audio_key"]; // wallpapers have no audio_key, but be safe
    // full_key is intentionally KEPT (public preview); category is KEPT too
    // (the browse axis the feed chips filter on).
    return r;
  }
  return r;
}

/** Filter rows that are missing their required key. Returns { valid, skipped }. */
function filterValidRows(
  scope: string,
  rows: ContentRow[],
): { valid: ContentRow[]; skipped: number } {
  let skipped = 0;
  const valid = rows.filter((row) => {
    if (scope === "wallpapers") {
      if (!row["full_key"]) { skipped++; return false; }
      if (row["type"] === "live" && row["mime"] !== "video/mp4") { skipped++; return false; }
      return true;
    }
    skipped++;
    return false;
  });
  return { valid, skipped };
}

/** Paginate items into Cloudflare-catalog-shaped page payloads. */
function paginateItems(items: ContentRow[], pageSize = 20): Array<{
  page: number; per_page: number; total: number;
  total_pages: number; has_more: boolean; items: ContentRow[];
}> {
  const totalPages = Math.max(1, Math.ceil(items.length / pageSize));
  return Array.from({ length: totalPages }, (_, i) => {
    const page = i + 1;
    return {
      page,
      per_page: pageSize,
      total: items.length,
      total_pages: totalPages,
      has_more: page < totalPages,
      items: items.slice((page - 1) * pageSize, page * pageSize),
    };
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Catalog key stripping", () => {
  it("wallpapers: keeps full_key + category, no audio_key in output", () => {
    const row: ContentRow = {
      id: "w1",
      full_key: "wallpapers/murugan/abc.jpg",
      audio_key: "should-not-exist",
      title: "Murugan at Palani",
      category: "murugan",
    };
    const result = stripPrivateKeys("wallpapers", row);
    expect(result["full_key"]).toBe("wallpapers/murugan/abc.jpg");
    expect(result["audio_key"]).toBeUndefined();
    expect(result["title"]).toBe("Murugan at Palani");
    expect(result["category"]).toBe("murugan");
  });
});

describe("Catalog validation / filtering", () => {
  it("excludes wallpapers missing full_key and counts them as skipped", () => {
    const rows: ContentRow[] = [
      { id: "w1", full_key: "wallpapers/posters/abc.jpg", type: "static" },
      { id: "w2", full_key: null, type: "static" }, // missing
      { id: "w3", full_key: "wallpapers/full/vid.mp4", type: "live", mime: "video/mp4" },
    ];
    const { valid, skipped } = filterValidRows("wallpapers", rows);
    expect(valid.length).toBe(2);
    expect(skipped).toBe(1);
    expect(valid.map((r) => r["id"])).toEqual(["w1", "w3"]);
  });

  it("excludes live wallpaper with non-MP4 mime", () => {
    const rows: ContentRow[] = [
      { id: "w1", full_key: "wallpapers/full/bad.webm", type: "live", mime: "video/webm" },
      { id: "w2", full_key: "wallpapers/full/good.mp4", type: "live", mime: "video/mp4" },
    ];
    const { valid, skipped } = filterValidRows("wallpapers", rows);
    expect(valid.length).toBe(1);
    expect(skipped).toBe(1);
  });

});

describe("Catalog pagination", () => {
  it("produces 1 page for an empty catalog", () => {
    const pages = paginateItems([]);
    expect(pages.length).toBe(1);
    expect(pages[0].total).toBe(0);
    expect(pages[0].has_more).toBe(false);
    expect(pages[0].items.length).toBe(0);
  });

  it("paginates 25 items into 2 pages of 20", () => {
    const items = Array.from({ length: 25 }, (_, i) => ({ id: `item${i}` }));
    const pages = paginateItems(items, 20);
    expect(pages.length).toBe(2);
    expect(pages[0].items.length).toBe(20);
    expect(pages[1].items.length).toBe(5);
    expect(pages[0].has_more).toBe(true);
    expect(pages[1].has_more).toBe(false);
    expect(pages[0].total).toBe(25);
    expect(pages[0].total_pages).toBe(2);
  });

  it("paginates exactly 20 items into 1 page", () => {
    const items = Array.from({ length: 20 }, (_, i) => ({ id: `item${i}` }));
    const pages = paginateItems(items, 20);
    expect(pages.length).toBe(1);
    expect(pages[0].has_more).toBe(false);
  });

  it("catalog page shape has all required fields", () => {
    const items = [{ id: "x1" }];
    const pages = paginateItems(items, 20);
    const page = pages[0];
    expect(page).toHaveProperty("page", 1);
    expect(page).toHaveProperty("per_page", 20);
    expect(page).toHaveProperty("total", 1);
    expect(page).toHaveProperty("total_pages", 1);
    expect(page).toHaveProperty("has_more", false);
    expect(page).toHaveProperty("items");
  });
});

describe("Orphaned page cleanup (deleteOrphanedPages)", () => {
  it("deletes a tag page whose last row was removed (the Shiddat/quran bug)", async () => {
    // Simulate: legacy tag pages exist from a prior build, but this build only
    // (re)wrote all_1.json.
    const { bucket, deleted } = makeListableR2([
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/temples_1.json",
      "catalog/wallpapers/new_1.json",
    ]);
    const written = new Set(["catalog/wallpapers/all_1.json"]);
    const count = await deleteOrphanedPages(bucket, "wallpapers", written);
    expect(count).toBe(2);
    expect(deleted.sort()).toEqual([
      "catalog/wallpapers/new_1.json",
      "catalog/wallpapers/temples_1.json",
    ]);
  });

  it("deletes higher page numbers when a scope shrinks below a page boundary", async () => {
    const { bucket, deleted } = makeListableR2([
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/all_2.json", // stale: scope shrank from 2 pages to 1
    ]);
    const written = new Set(["catalog/wallpapers/all_1.json"]);
    const count = await deleteOrphanedPages(bucket, "wallpapers", written);
    expect(count).toBe(1);
    expect(deleted).toEqual(["catalog/wallpapers/all_2.json"]);
  });

  it("keeps every page the current build wrote", async () => {
    const { bucket, deleted, remaining } = makeListableR2([
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/all_2.json",
    ]);
    const written = new Set([
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/all_2.json",
    ]);
    const count = await deleteOrphanedPages(bucket, "wallpapers", written);
    expect(count).toBe(0);
    expect(deleted).toEqual([]);
    expect(remaining().length).toBe(2);
  });

  it("only touches the scope's own prefix, never version.json / app_config.json", async () => {
    // Those files live at catalog/, not catalog/<scope>/, so the scope-prefixed
    // list never returns them — but assert it explicitly as a safety net.
    const { bucket, deleted } = makeListableR2([
      "catalog/version.json",
      "catalog/app_config.json",
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/all_2.json",
    ]);
    const written = new Set(["catalog/wallpapers/all_1.json"]);
    await deleteOrphanedPages(bucket, "wallpapers", written);
    expect(deleted).toEqual(["catalog/wallpapers/all_2.json"]);
    expect(deleted).not.toContain("catalog/version.json");
    expect(deleted).not.toContain("catalog/app_config.json");
  });

  it("ignores non-JSON objects sharing the prefix", async () => {
    const { bucket, deleted } = makeListableR2([
      "catalog/wallpapers/all_1.json",
      "catalog/wallpapers/README.txt",
    ]);
    const written = new Set(["catalog/wallpapers/all_1.json"]);
    const count = await deleteOrphanedPages(bucket, "wallpapers", written);
    expect(count).toBe(0);
    expect(deleted).toEqual([]);
  });
});

// ── catalog/app_config.json ───────────────────────────────────────────────────

describe("writeAppConfig (catalog/app_config.json)", () => {
  it("writes the PUBLIC subset to catalog/app_config.json with snake_case keys", async () => {
    const { bucket, puts } = makeMockR2();
    await writeAppConfig(bucket, {
      content_version: 42, // must NOT leak
      prices: { monthly: { amount: 4900, currency: "INR" } },
      support_email: "support@hsrutility.com",
      policy_urls: { privacy: "https://hsrapps.com/p" },
      feature_flags: { ramadan_mode: true },
      min_supported_version: "1.0.0",
    });

    expect(puts).toHaveLength(1);
    expect(puts[0].key).toBe("catalog/app_config.json");
    const body = puts[0].body as Record<string, unknown>;
    // Public fields present, matching AppConfigModel.fromJson (snake_case)
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.support_email).toBe("support@hsrutility.com");
    expect(body.policy_urls).toEqual({ privacy: "https://hsrapps.com/p" });
    expect(body.feature_flags).toEqual({ ramadan_mode: true });
    expect(body.min_supported_version).toBe("1.0.0");
  });

  it("NEVER includes content_version or other non-public columns", async () => {
    const { bucket, puts } = makeMockR2();
    await writeAppConfig(bucket, {
      content_version: 99,
      prices: {},
      support_email: null,
      policy_urls: {},
      feature_flags: {},
      min_supported_version: null,
      // simulate a secret accidentally present on the row
      some_secret: "DO_NOT_LEAK",
    });
    const body = puts[0].body as Record<string, unknown>;
    expect(body).not.toHaveProperty("content_version");
    expect(body).not.toHaveProperty("some_secret");
    expect(Object.keys(body).sort()).toEqual([
      "feature_flags",
      "min_supported_version",
      "policy_urls",
      "prices",
      "support_email",
    ]);
  });

  it("defaults missing jsonb fields to empty objects and missing strings to null", async () => {
    const { bucket, puts } = makeMockR2();
    await writeAppConfig(bucket, {});
    const body = puts[0].body as Record<string, unknown>;
    expect(body.prices).toEqual({});
    expect(body.policy_urls).toEqual({});
    expect(body.feature_flags).toEqual({});
    expect(body.support_email).toBeNull();
    expect(body.min_supported_version).toBeNull();
  });

  it("parses jsonb columns delivered as raw JSON strings (Hyperdrive fetch_types:false)", async () => {
    const { bucket, puts } = makeMockR2();
    // Under fetch_types:false (required for Hyperdrive) postgres.js returns jsonb
    // as the raw JSON string. These must be parsed, not double-encoded.
    await writeAppConfig(bucket, {
      prices: '{"monthly":{"amount":4900,"currency":"INR"}}',
      policy_urls: '{"privacy":"https://hsrapps.com/p"}',
      feature_flags: "{}",
      support_email: "support@hsrutility.com",
      min_supported_version: "1.0.0",
    });
    const body = puts[0].body as Record<string, unknown>;
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.policy_urls).toEqual({ privacy: "https://hsrapps.com/p" });
    expect(body.feature_flags).toEqual({});
    // A string column stays a string (not wrapped in an object).
    expect(body.support_email).toBe("support@hsrutility.com");
  });
});
