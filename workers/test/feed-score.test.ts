import { describe, it, expect } from "vitest";

import { RANK_STEP, STATUS_FRESH_MS, rankFor, statusWeight, weightedShuffle } from "../src/lib/feed-score.js";

// All that is left of the feed-order module is the rank NUMBERING the catalog emits
// It has no runtime failure mode, which is exactly WHY it is pinned here
// A wrong step or an off-by-one still builds a valid catalog -> the app just sorts it differently from the CMS
// Nobody notices that until someone compares the two by hand -> the test is the only alarm
// The ORDER itself is an ORDER BY inside buildScope() (statuses: the shuffle below) -> the smoke plan covers it
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

// The status draw weight -> wrong numbers still build a valid catalog, so these are the only alarm
describe("statusWeight", () => {
  const now = new Date("2026-10-14T12:00:00Z");
  const ago = (ms: number) => new Date(now.getTime() - ms);

  it("gives an old, unused clip the floor of 1, never 0 -> every clip can still lead", () => {
    expect(statusWeight({ uses: 0, freshAt: ago(30 * 86_400_000) }, 500, now)).toBe(1);
    expect(statusWeight({ uses: 0, freshAt: null }, 0, now)).toBe(1);
  });

  it("gives the busiest clip and a just-published one the same 4x", () => {
    expect(statusWeight({ uses: 500, freshAt: null }, 500, now)).toBe(4);
    expect(statusWeight({ uses: 0, freshAt: now }, 500, now)).toBe(4);
  });

  it("fades the fresh boost to nothing at exactly 7 days, and halfway at 3.5", () => {
    expect(statusWeight({ uses: 0, freshAt: ago(STATUS_FRESH_MS / 2) }, 0, now)).toBeCloseTo(2.5);
    expect(statusWeight({ uses: 0, freshAt: ago(STATUS_FRESH_MS) }, 0, now)).toBe(1);
  });

  it("caps a future timestamp at fully fresh", () => {
    expect(statusWeight({ uses: 0, freshAt: new Date(now.getTime() + 86_400_000) }, 0, now)).toBe(4);
  });

  it("log-scales uses, so ten times the shares is far less than ten times the weight", () => {
    const w10 = statusWeight({ uses: 10, freshAt: null }, 1000, now);
    const w100 = statusWeight({ uses: 100, freshAt: null }, 1000, now);
    expect(w100).toBeGreaterThan(w10);
    expect((w100 - 1) / (w10 - 1)).toBeLessThan(2);
  });
});

describe("weightedShuffle", () => {
  it("returns every row exactly once", () => {
    const rows = Array.from({ length: 100 }, (_, i) => i);
    const out = weightedShuffle(rows, (r) => 1 + (r % 4));
    expect([...out].sort((a, b) => a - b)).toEqual(rows);
  });

  it("puts a row first in proportion to its weight", () => {
    let seed = 7;
    const random = () => {
      seed = (seed * 1664525 + 1013904223) % 2 ** 32;
      return seed / 2 ** 32;
    };
    let heavyFirst = 0;
    for (let i = 0; i < 4000; i++) {
      if (weightedShuffle(["light", "heavy"], (r) => (r === "heavy" ? 3 : 1), random)[0] === "heavy")
        heavyFirst++;
    }
    // 3 / (3 + 1) = 75%
    expect(heavyFirst / 4000).toBeGreaterThan(0.72);
    expect(heavyFirst / 4000).toBeLessThan(0.78);
  });
});
