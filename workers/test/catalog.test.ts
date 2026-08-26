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
import {
  writeAppConfig,
  deleteOrphanedPages,
  interleaveByCategory,
  composeFeedOrder,
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
      policy_urls: { privacy: "https://hsrutility.com/p" },
      feature_flags: { ramadan_mode: true },
      min_supported_version: "1.0.0",
    });

    expect(puts).toHaveLength(1);
    expect(puts[0].key).toBe("catalog/app_config.json");
    const body = puts[0].body as Record<string, unknown>;
    // Public fields present, matching AppConfigModel.fromJson (snake_case)
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.support_email).toBe("support@hsrutility.com");
    expect(body.policy_urls).toEqual({ privacy: "https://hsrutility.com/p" });
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
      policy_urls: '{"privacy":"https://hsrutility.com/p"}',
      feature_flags: "{}",
      support_email: "support@hsrutility.com",
      min_supported_version: "1.0.0",
    });
    const body = puts[0].body as Record<string, unknown>;
    expect(body.prices).toEqual({ monthly: { amount: 4900, currency: "INR" } });
    expect(body.policy_urls).toEqual({ privacy: "https://hsrutility.com/p" });
    expect(body.feature_flags).toEqual({});
    // A string column stays a string (not wrapped in an object).
    expect(body.support_email).toBe("support@hsrutility.com");
  });
});

// ── interleaveByCategory ─────────────────────────────────────────────────────
// This decides what the app's All chip opens with, so its contract is a product
// contract. Guarded here because the failure is invisible in code review: the
// build succeeds, the catalog is valid, and the feed is simply wrong.
describe("interleaveByCategory", () => {
  const rows = (spec: Record<string, number>) =>
    Object.entries(spec).flatMap(([cat, n]) =>
      Array.from({ length: n }, (_, i) => ({ id: `${cat}${i}`, category: cat })),
    );

  it("deals one per category, so a bulk import cannot own the first screen", () => {
    // The 2026-08-14 production shape: one import block, then another.
    const out = interleaveByCategory(rows({ perumal: 20, sivan: 10, amman: 5 }));

    expect(out.slice(0, 6).map((r) => r.category)).toEqual([
      "perumal", "sivan", "amman",
      "perumal", "sivan", "amman",
    ]);
  });

  it("never reorders two rows of the SAME category", () => {
    // Category chips filter this one page set, so this is what keeps a chip
    // reading newest-first after the interleave.
    const out = interleaveByCategory(rows({ sivan: 4, amman: 4 }));

    expect(out.filter((r) => r.category === "sivan").map((r) => r.id)).toEqual([
      "sivan0", "sivan1", "sivan2", "sivan3",
    ]);
  });

  it("is idempotent — a rebuild never churns the feed", () => {
    const once = interleaveByCategory(rows({ a: 7, b: 5, c: 3 }));
    const twice = interleaveByCategory(once);
    expect(twice.map((r) => r.id)).toEqual(once.map((r) => r.id));
  });

  it("is a permutation — never drops or duplicates a row", () => {
    const input = rows({ a: 9, b: 4, c: 1, d: 6 });
    const out = interleaveByCategory(input);
    expect(out).toHaveLength(input.length);
    expect(new Set(out.map((r) => r.id))).toEqual(
      new Set(input.map((r) => r.id)),
    );
  });

  it("drains an exhausted category instead of stalling", () => {
    // Unequal counts are the normal case; the largest category tails alone.
    const out = interleaveByCategory(rows({ big: 5, small: 1 }));
    expect(out.map((r) => r.category)).toEqual([
      "big", "small", "big", "big", "big", "big",
    ]);
  });

  it("leaves a single-category catalog in plain catalog order", () => {
    const input = rows({ only: 4 });
    expect(interleaveByCategory(input).map((r) => r.id)).toEqual(
      input.map((r) => r.id),
    );
  });

  it("does not depend on Map iteration luck when sizes tie", () => {
    // Equal-sized categories break on name, so the cycle is reproducible.
    const a = interleaveByCategory(rows({ zebra: 3, alpha: 3 }));
    const b = interleaveByCategory(rows({ alpha: 3, zebra: 3 }));
    expect(a.map((r) => r.category)).toEqual(b.map((r) => r.category));
    expect(a[0].category).toBe("alpha");
  });

  it("handles an empty catalog", () => {
    expect(interleaveByCategory([])).toEqual([]);
  });
});

// ── composeFeedOrder ─────────────────────────────────────────────────────────
// THE feed order (CLAUDE.md §5b). Same reasoning as above: a wrong answer here
// builds cleanly and ships a valid catalog that is simply in the wrong order.
// The cohort-tie case is the load-bearing one — it is what keeps a bulk import
// from owning the opening screens as a single-category block.
describe("composeFeedOrder", () => {
  const NOW = new Date("2026-09-01T00:00:00Z");
  const daysAgo = (n: number) =>
    new Date(NOW.getTime() - n * 24 * 60 * 60 * 1000).toISOString();

  /** Rows of a given category, all created `age` days ago with no applies. */
  const rows = (spec: Record<string, number>, age = 0) =>
    Object.entries(spec).flatMap(([cat, n]) =>
      Array.from({ length: n }, (_, i) => ({
        id: `${cat}${i}`,
        category: cat,
        created_at: daysAgo(age),
        apply_score: 0,
        scored_at: null,
      })),
    );
  /** Give `id` a decayed score, as if last applied `days` ago. */
  const applied = <T extends { id: string }>(
    list: T[],
    spec: Record<string, [number, number]>,
  ) =>
    list.map((r) =>
      spec[r.id]
        ? { ...r, apply_score: spec[r.id][0], scored_at: daysAgo(spec[r.id][1]) }
        : r,
    );
  const order = (list: Record<string, unknown>[]) =>
    composeFeedOrder(list, NOW, "apply_score").map((r) => r["id"]);

  it("puts the highest merit score first, across categories", () => {
    const out = order(
      applied(rows({ perumal: 3, sivan: 3, amman: 3 }, 90), {
        amman2: [4, 0],
        perumal1: [9, 0],
        sivan0: [1, 0],
      }),
    );
    expect(out.slice(0, 3)).toEqual(["perumal1", "amman2", "sivan0"]);
  });

  it("decays: an older apply loses to a newer one of the same size", () => {
    // Both rows earned 4 applies. One earned them 90 days ago (three half-lives
    // → 0.5), the other today. Ordering on the raw count would tie them forever;
    // that tie is exactly the frozen head this feature exists to break.
    const out = order(
      applied(rows({ a: 1, b: 1 }, 90), { a0: [4, 90], b0: [4, 0] }),
    );
    expect(out).toEqual(["b0", "a0"]);
  });

  it("a stale favourite falls below a modest recent one", () => {
    // 40 applies, none for a year (≈12 half-lives → ~0.01) vs 2 applies today.
    const out = order(
      applied(rows({ a: 1, b: 1 }, 400), { a0: [40, 365], b0: [2, 0] }),
    );
    expect(out).toEqual(["b0", "a0"]);
  });

  it("a brand-new row outranks the never-applied tail", () => {
    // The newcomer credit IS the catch-up: without it a new row would sit below
    // everything forever, never seen and so never applied.
    const old = rows({ a: 5 }, 400);
    const fresh = rows({ b: 1 }, 0);
    expect(order([...old, ...fresh])[0]).toBe("b0");
  });

  it("a fresh import does NOT own the opening screens as one block", () => {
    // The trap: 20 Perumal + 10 Sivan imported the same day. A credit that varied
    // continuously with age would order them strictly by created_at and hand the
    // first 20 slots to one category (the 2026-08-14 defect). Stepping the credit
    // makes the whole cohort tie, so the interleave governs.
    const out = order([...rows({ perumal: 20 }, 1), ...rows({ sivan: 10 }, 2)]);
    expect(out.slice(0, 4)).toEqual(["perumal0", "sivan0", "perumal1", "sivan1"]);
  });

  it("the credit steps down, so last week's cohort sits below this week's", () => {
    const out = order([...rows({ a: 2 }, 10), ...rows({ b: 2 }, 1)]);
    expect(out).toEqual(["b0", "b1", "a0", "a1"]);
  });

  it("the long tail ties at exactly zero and stays interleaved", () => {
    // Past CREDIT_FLOOR the credit is zeroed rather than left as a vanishing
    // fraction — otherwise the whole never-applied tail would order by age.
    const out = order([...rows({ perumal: 3 }, 300), ...rows({ sivan: 3 }, 400)]);
    expect(out).toEqual([
      "perumal0", "sivan0", "perumal1", "sivan1", "perumal2", "sivan2",
    ]);
  });

  it("breaks a tie on interleaved catalog position, so the order is TOTAL", () => {
    const input = rows({ a: 2, b: 2 }, 400);
    expect(order(input)).toEqual(order(input));
    expect(order(input)).toEqual(["a0", "b0", "a1", "b1"]);
  });

  it("is idempotent — a rebuild never churns the feed", () => {
    const input = applied(rows({ a: 7, b: 5, c: 3 }, 30), {
      b1: [3, 2], c0: [1, 10], a4: [8, 0],
    });
    const once = composeFeedOrder(input, NOW, "apply_score");
    const twice = composeFeedOrder(once, NOW, "apply_score");
    expect(twice.map((r) => r.id)).toEqual(once.map((r) => r.id));
  });

  it("is a permutation — never drops or duplicates a row", () => {
    const input = applied(rows({ a: 9, b: 4, c: 1, d: 6 }, 5), {
      a3: [2, 1], d0: [5, 0],
    });
    const out = composeFeedOrder(input, NOW, "apply_score");
    expect(out).toHaveLength(input.length);
    expect(new Set(out.map((r) => r.id))).toEqual(
      new Set(input.map((r) => r.id)),
    );
  });

  it("with no scores at all it IS interleaveByCategory", () => {
    // Day one, and the permanent state of the tail. No merit data must mean no
    // behaviour change from the order that shipped before scoring existed.
    const input = rows({ perumal: 20, sivan: 10, amman: 5 }, 400);
    expect(order(input)).toEqual(
      interleaveByCategory(input).map((r) => r.id),
    );
  });

  it("survives junk in the score columns", () => {
    // Defensive: a bad value costs ONE row its merit, it never corrupts the rest.
    const input = [
      { id: "a0", category: "a", created_at: daysAgo(400), apply_score: "nope", scored_at: "also-nope" },
      { id: "a1", category: "a", created_at: daysAgo(400), apply_score: 5, scored_at: daysAgo(0) },
    ];
    expect(order(input)).toEqual(["a1", "a0"]);
  });

  it("handles an empty catalog", () => {
    expect(composeFeedOrder([], NOW, "apply_score")).toEqual([]);
  });
});
