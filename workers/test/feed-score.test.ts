import { describe, it, expect } from "vitest";

import {
  CREDIT_FLOOR,
  HALF_LIFE_DAYS,
  HALF_LIFE_SECONDS,
  NEWCOMER_CREDIT,
  NEWCOMER_HALF_LIFE_DAYS,
  decayedUses,
  feedScore,
  newcomerCredit,
  rankFor,
  toDate,
  toScore,
} from "../src/lib/feed-score.js";

// The scoring maths behind the whole feed order. None of this has a runtime
// failure mode — a wrong constant or a sign error still builds a valid catalog,
// just in the wrong order, and nobody notices until the feed has been frozen or
// churning for a week. The properties, not the numbers, are what is pinned here.

const NOW = new Date("2026-09-01T00:00:00Z");
const daysAgo = (n: number) =>
  new Date(NOW.getTime() - n * 24 * 60 * 60 * 1000).toISOString();

describe("decayedUses", () => {
  it("halves over one half-life", () => {
    expect(decayedUses(8, daysAgo(HALF_LIFE_DAYS), NOW)).toBeCloseTo(4, 6);
    expect(decayedUses(8, daysAgo(HALF_LIFE_DAYS * 2), NOW)).toBeCloseTo(2, 6);
  });

  it("is unchanged at zero elapsed time", () => {
    expect(decayedUses(3, daysAgo(0), NOW)).toBeCloseTo(3, 6);
  });

  it("never inflates on a clock skew", () => {
    // A `scored_at` in the future (DB clock ahead of the build) must not
    // multiply the score up.
    expect(decayedUses(3, daysAgo(-5), NOW)).toBe(3);
  });

  it("scores 0 with no reference instant", () => {
    // scored_at null means the apply path never wrote this row. Treating it as
    // "applied right now" would hand a free top slot to any row whose score was
    // seeded without a timestamp.
    expect(decayedUses(9, null, NOW)).toBe(0);
    expect(decayedUses(9, undefined, NOW)).toBe(0);
  });

  it("PRESERVES RELATIVE ORDER as time passes — the stability property", () => {
    // Two rows keep their ratio however long the gap to the next rebuild, so the
    // merit half of the feed never churns on a clock: it moves only when a real
    // apply lands. The app diffs served lists by ordered ids, so a feed that
    // reshuffled on its own would re-point the pager and the video pool under a
    // scrolling user.
    const later = new Date(NOW.getTime() + 45 * 24 * 60 * 60 * 1000);
    const a = { s: 10, at: daysAgo(60) };
    const b = { s: 3, at: daysAgo(5) };
    const nowGap = decayedUses(a.s, a.at, NOW) - decayedUses(b.s, b.at, NOW);
    const laterGap =
      decayedUses(a.s, a.at, later) - decayedUses(b.s, b.at, later);
    expect(Math.sign(nowGap)).toBe(Math.sign(laterGap));
  });
});

describe("newcomerCredit", () => {
  it("gives a brand-new row the full credit", () => {
    expect(newcomerCredit(daysAgo(0), NOW)).toBe(NEWCOMER_CREDIT);
  });

  it("STEPS rather than sliding — a whole cohort ties exactly", () => {
    // The tie is the mechanism, not an accident: it is what leaves an imported
    // batch to the category interleave instead of letting age order it into a
    // single-category block at the head of the feed.
    const a = newcomerCredit(daysAgo(1), NOW);
    const b = newcomerCredit(daysAgo(NEWCOMER_HALF_LIFE_DAYS - 0.01), NOW);
    expect(a).toBe(b);
  });

  it("halves at each step boundary", () => {
    expect(newcomerCredit(daysAgo(NEWCOMER_HALF_LIFE_DAYS), NOW)).toBe(
      NEWCOMER_CREDIT / 2,
    );
    expect(newcomerCredit(daysAgo(NEWCOMER_HALF_LIFE_DAYS * 2), NOW)).toBe(
      NEWCOMER_CREDIT / 4,
    );
  });

  it("zeroes past the floor, so the old tail ties at exactly 0", () => {
    expect(newcomerCredit(daysAgo(365), NOW)).toBe(0);
    expect(newcomerCredit(daysAgo(NEWCOMER_HALF_LIFE_DAYS * 20), NOW)).toBe(0);
    expect(CREDIT_FLOOR).toBeGreaterThan(0);
  });

  it("gives nothing to a row with no creation date", () => {
    expect(newcomerCredit(null, NOW)).toBe(0);
    expect(newcomerCredit("not-a-date", NOW)).toBe(0);
  });

  it("treats a future created_at as brand new, never as negative", () => {
    expect(newcomerCredit(daysAgo(-3), NOW)).toBe(NEWCOMER_CREDIT);
  });
});

describe("feedScore", () => {
  it("keeps the two terms separate for the CMS, and sums them", () => {
    const s = feedScore(
      { score: 4, scoredAt: daysAgo(HALF_LIFE_DAYS), createdAt: daysAgo(0) },
      NOW,
    );
    expect(s.recent).toBeCloseTo(2, 6);
    expect(s.credit).toBe(NEWCOMER_CREDIT);
    expect(s.total).toBeCloseTo(2 + NEWCOMER_CREDIT, 6);
  });

  it("an unused old row scores exactly 0", () => {
    const s = feedScore(
      { score: 0, scoredAt: null, createdAt: daysAgo(400) },
      NOW,
    );
    expect(s.total).toBe(0);
  });
});

describe("column coercion", () => {
  // postgres.js runs with fetch_types:false (required for Hyperdrive) and hands
  // several types back as strings. Silently scoring those as 0 would flatten the
  // whole feed to interleaved catalog order without any error anywhere.
  it("reads a double precision that arrived as a string", () => {
    expect(toScore("4.5")).toBe(4.5);
  });

  it("reads a timestamptz that arrived as an ISO string", () => {
    expect(toDate("2026-09-01T00:00:00Z")?.getTime()).toBe(NOW.getTime());
  });

  it("folds junk and negatives to 0 / null rather than throwing", () => {
    expect(toScore("nope")).toBe(0);
    expect(toScore(-3)).toBe(0);
    expect(toScore(null)).toBe(0);
    expect(toDate("nope")).toBeNull();
    expect(toDate(12345)).toBeNull();
  });
});

describe("constants", () => {
  it("HALF_LIFE_SECONDS matches HALF_LIFE_DAYS", () => {
    // The write path decays in SQL with the seconds value while every read uses
    // the days value. If these ever disagreed, every score would be quietly
    // wrong and nothing would fail.
    expect(HALF_LIFE_SECONDS).toBe(HALF_LIFE_DAYS * 24 * 60 * 60);
  });

  it("ranks are sparse and 1-based", () => {
    expect(rankFor(0)).toBe(10);
    expect(rankFor(1)).toBe(20);
  });
});
