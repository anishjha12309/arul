/**
 * The submission-sweep DECISION logic.
 * sweepSubmissions() needs a live DB and R2 binding -> only the pure `selectKeysToDelete` core is testable here
 */

import { describe, it, expect } from "vitest";
import {
  selectKeysToDelete,
  SWEEP_GRACE_MS,
  type SweepCandidate,
} from "../src/cron/sweep-submissions.js";

const NOW = 1_700_000_000_000;
const OLD = NOW - SWEEP_GRACE_MS - 1; // just past the grace window
const FRESH = NOW - 1; // uploaded a moment ago

function obj(key: string, uploadedMs: number): SweepCandidate {
  return { key, uploadedMs };
}

describe("selectKeysToDelete", () => {
  it("keeps objects that still back a pending submission", () => {
    const key = "user/u1/submissions/100_a.mp4";
    const out = selectKeysToDelete([obj(key, OLD)], new Set([key]), NOW);
    expect(out).toEqual([]);
  });

  it("deletes approved/rejected leftovers (old, no longer pending)", () => {
    const key = "user/u1/submissions/100_a.mp4";
    const out = selectKeysToDelete([obj(key, OLD)], new Set(), NOW);
    expect(out).toEqual([key]);
  });

  it("deletes orphans that have no submission row at all", () => {
    const key = "user/u9/submissions/999_abandoned.jpg";
    const out = selectKeysToDelete([obj(key, OLD)], new Set(), NOW);
    expect(out).toEqual([key]);
  });

  it("never deletes objects inside the grace window (in-flight uploads)", () => {
    const key = "user/u1/submissions/100_a.mp4";
    const out = selectKeysToDelete([obj(key, FRESH)], new Set(), NOW);
    expect(out).toEqual([]);
  });

  it("ignores keys that are not submission objects", () => {
    // The prefix is user/ but the INFIX guard is what actually scopes the sweep -> anything else is out of scope
    const out = selectKeysToDelete(
      [obj("user/u1/profile/avatar.png", OLD)],
      new Set(),
      NOW,
    );
    expect(out).toEqual([]);
  });

  it("partitions a mixed listing correctly", () => {
    const pending = "user/u1/submissions/1_keep.mp4";
    const fresh = "user/u2/submissions/2_fresh.jpg";
    const stale = "user/u3/submissions/3_stale.mp3";
    const out = selectKeysToDelete(
      [obj(pending, OLD), obj(fresh, FRESH), obj(stale, OLD)],
      new Set([pending]),
      NOW,
    );
    expect(out).toEqual([stale]);
  });
});
