import { describe, it, expect } from "vitest";

import { RANK_STEP, rankFor } from "../src/lib/feed-score.js";

// All that is left of the feed-order module is the rank NUMBERING the catalog emits
// It has no runtime failure mode, which is exactly WHY it is pinned here
// A wrong step or an off-by-one still builds a valid catalog -> the app just sorts it differently from the CMS
// Nobody notices that until someone compares the two by hand -> the test is the only alarm
// The ORDER itself is an ORDER BY inside buildScope() and needs a live DB -> the smoke plan covers it
describe("rankFor", () => {
  it("is 1-based, so the first row is never rank 0", () => {
    // 0 is falsy, and the shipped comparator reads a null or absent rank as "unpinned"
    // A rank of 0 is one loose `if (rank)` away from meaning that -> ranks must start at RANK_STEP
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
    // Emitted into JSON and parsed as an INT by the Flutter model -> a float here is a parse failure on device
    for (const i of [0, 1, 99, 999, 5000]) {
      expect(Number.isInteger(rankFor(i))).toBe(true);
    }
  });
});
