import { describe, it, expect } from "vitest";

import { RANK_STEP, rankFor } from "../src/lib/feed-score.js";

// What is left of the feed-order module after the decayed merit score was
// retired (2026-08-27): the rank NUMBERING the catalog emits.
//
// This has no runtime failure mode, which is exactly why it is pinned. A wrong
// step or an off-by-one still builds a valid catalog — the app just sorts it
// differently from what the CMS says it will, and nobody notices until someone
// compares the two by hand. The ORDER itself is now an ORDER BY inside
// buildScope() and needs a live DB; the live smoke plan covers it.
describe("rankFor", () => {
  it("is 1-based, so the first row is never rank 0", () => {
    // 0 is falsy, and the shipped app comparator treats a null/absent rank as
    // "unpinned". A rank of 0 is one loose `if (rank)` away from meaning that.
    expect(rankFor(0)).toBe(RANK_STEP);
    expect(rankFor(0)).toBeGreaterThan(0);
  });

  it("is sparse, so positions can be re-cut without renumbering everything", () => {
    expect(rankFor(1) - rankFor(0)).toBe(RANK_STEP);
    expect(RANK_STEP).toBeGreaterThan(1);
  });

  it("is strictly increasing — rank order IS feed order", () => {
    const ranks = Array.from({ length: 50 }, (_, i) => rankFor(i));
    for (let i = 1; i < ranks.length; i++) {
      expect(ranks[i]).toBeGreaterThan(ranks[i - 1]!);
    }
  });

  it("never collides, so two rows cannot claim one slot", () => {
    const ranks = Array.from({ length: 500 }, (_, i) => rankFor(i));
    expect(new Set(ranks).size).toBe(ranks.length);
  });

  it("stays an exact integer across a whole catalog", () => {
    // Emitted into JSON and parsed as an int by the Flutter model — a float
    // here would be a parse failure on device, not a slightly-off order.
    for (const i of [0, 1, 99, 999, 5000]) {
      expect(Number.isInteger(rankFor(i))).toBe(true);
    }
  });
});
