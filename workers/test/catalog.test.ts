/**
 * Unit tests for the exported, R2-facing halves of build-catalog:
 *   1. deleteOrphanedPages — stale page cleanup after a shrinking build
 *   2. writeAppConfig      — config payload + cache headers
 *
 * NOT covered here: the row shaping inside buildScope() (key stripping,
 * validation, pagination, pgTextArrayToList). That logic is unexported and
 * inlined, so it is unreachable from a test. It was previously "covered" by
 * copies of the logic redefined in this file; those copies silently drifted
 * out of sync with production (the wallpaper strip-list lost five columns),
 * so they were removed rather than left to give false confidence. Export the
 * real helpers from build-catalog.ts to test them for real.
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
