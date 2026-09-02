/**
 * The exported, R2-facing halves of build-catalog: deleteOrphanedPages and writeAppConfig.
 *
 * NOT covered: the row shaping inside buildScope() -> that logic is unexported and inlined, so no test can reach it
 * It was once "covered" by copies of the logic redefined here -> those copies silently drifted from production
 * They were deleted rather than left giving false confidence -> EXPORT the real helpers to test them for real
 */

import { describe, it, expect, vi } from "vitest";
import {
  writeAppConfig,
  deleteOrphanedPages,
  readCategoryOrder,
} from "../src/cron/build-catalog.js";

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

describe("Orphaned page cleanup (deleteOrphanedPages)", () => {
  it("deletes a tag page whose last row was removed (the Shiddat/quran bug)", async () => {
    // Legacy tag pages survive from a prior build, but this build only rewrote all_1.json -> the rest are orphans
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
    // version.json and app_config.json live at catalog/, not catalog/<scope>/ -> the scoped list cannot return them
    // Assert it explicitly anyway -> deleting either one would break every install at once
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
      policy_urls: { privacy: "https://hsrutility.com/p" },
      feature_flags: { ramadan_mode: true },
      min_supported_version: "1.0.0",
    });

    expect(puts).toHaveLength(1);
    expect(puts[0].key).toBe("catalog/app_config.json");
    const body = puts[0].body as Record<string, unknown>;
    // The public fields must match AppConfigModel.fromJson exactly -> a renamed key fails to parse on device
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.support_email).toBe("support@hsrutility.com");
    expect(body.policy_urls).toEqual({ privacy: "https://hsrutility.com/p" });
    expect(body.feature_flags).toEqual({ ramadan_mode: true });
    expect(body.min_supported_version).toBe("1.0.0");
  });

  it("carries the hand-set chip order, keyed by SCOPE the way the app reads it", async () => {
    const { bucket, puts } = makeMockR2();
    await writeAppConfig(
      bucket,
      {},
      { wallpapers: ["amman", "sivan"], ringtones: ["others", "murugan"] },
    );
    const body = puts[0].body as Record<string, unknown>;
    expect(body.category_order).toEqual({
      wallpapers: ["amman", "sivan"],
      ringtones: ["others", "murugan"],
    });
  });

  it("emits an EMPTY order when nothing is positioned -> the app keeps its built-in rule", async () => {
    const { bucket, puts } = makeMockR2();
    await writeAppConfig(bucket, {});
    expect((puts[0].body as Record<string, unknown>).category_order).toEqual({});
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
      // A secret accidentally present on the row -> writeAppConfig must drop it, not pass it through
      some_secret: "DO_NOT_LEAK",
    });
    const body = puts[0].body as Record<string, unknown>;
    expect(body).not.toHaveProperty("content_version");
    expect(body).not.toHaveProperty("some_secret");
    expect(Object.keys(body).sort()).toEqual([
      "category_order",
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
    // Under `fetch_types:false` postgres.js returns jsonb as the raw JSON STRING -> parse it, never double-encode
    await writeAppConfig(bucket, {
      prices: '{"monthly":{"amount":4900,"currency":"INR"}}',
      policy_urls: '{"privacy":"https://hsrutility.com/p"}',
      feature_flags: "{}",
      support_email: "support@hsrutility.com",
      min_supported_version: "1.0.0",
    });
    const body = puts[0].body as Record<string, unknown>;
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.policy_urls).toEqual({ privacy: "https://hsrutility.com/p" });
    expect(body.feature_flags).toEqual({});
    // A plain string column stays a string -> the jsonb coercion must not wrap it in an object
    expect(body.support_email).toBe("support@hsrutility.com");
  });
});

// ── Feed order ───────────────────────────────────────────────────────────────
// There is nothing left here to unit-test, and that is the POINT
// The order used to be two exported pure functions implementing a decayed merit score
// This file carried ~200 lines pinning them -> a wrong answer there built cleanly and shipped a valid, wrong order
// The order is now one ORDER BY inside buildScope() -> it needs a live DB -> the smoke plan covers it
// What remains in JS is the rank NUMBERING -> test/feed-score.test.ts pins that
// If ordering logic ever moves back into JS, it belongs here again

// ── the hand-set chip order (categories table -> catalog) ─────────────────────

describe("readCategoryOrder", () => {
  /** Tagged-template stub: one row set, or a throw. */
  function sqlStub(rows: unknown[] | Error) {
    return (() =>
      rows instanceof Error ? Promise.reject(rows) : Promise.resolve(rows)) as never;
  }

  it("groups by scope and preserves the CMS's picker_order", async () => {
    const order = await readCategoryOrder(
      sqlStub([
        { kind: "ringtone", slug: "others" },
        { kind: "ringtone", slug: "sivan" },
        { kind: "wallpaper", slug: "amman" },
        { kind: "wallpaper", slug: "ayyappan" },
      ]),
    );
    // Singular CMS kind -> plural catalog scope. Getting this wrong ships an
    // order under a key the app never looks up, which fails silently.
    expect(order).toEqual({
      ringtones: ["others", "sivan"],
      wallpapers: ["amman", "ayyappan"],
    });
  });

  it("answers {} when the categories table does not exist yet", async () => {
    const missing = Object.assign(new Error('relation "categories" does not exist'), {
      code: "42P01",
    });
    expect(await readCategoryOrder(sqlStub(missing))).toEqual({});
  });

  it("answers {} on any other DB error rather than failing the whole build", async () => {
    // A catalog build that dies over a cosmetic ordering column would withhold
    // version.json for EVERY scope and freeze the feed.
    expect(await readCategoryOrder(sqlStub(new Error("boom")))).toEqual({});
  });
});
