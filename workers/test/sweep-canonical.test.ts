/**
 * Unit tests for the canonical-media sweep decision logic.
 *
 * sweepCanonical() itself needs a live DB + R2 binding, so we test the pure
 * `selectCanonicalKeysToDelete` core: given the objects seen, the keys still
 * referenced by wallpapers/ringtones rows, and `now`, decide which to delete.
 */

import { describe, it, expect } from "vitest";
import {
  selectCanonicalKeysToDelete,
  CANONICAL_GRACE_MS,
  type CanonicalCandidate,
} from "../src/cron/sweep-canonical.js";

const NOW = 1_700_000_000_000;
const OLD = NOW - CANONICAL_GRACE_MS - 1; // just past the grace window
const FRESH = NOW - 1; // uploaded a moment ago

function obj(key: string, uploadedMs: number): CanonicalCandidate {
  return { key, uploadedMs };
}

describe("selectCanonicalKeysToDelete", () => {
  it("keeps objects referenced by a row (published or draft alike)", () => {
    const key = "wallpapers/full/abc.mp4";
    const out = selectCanonicalKeysToDelete([obj(key, OLD)], new Set([key]), NOW);
    expect(out).toEqual([]);
  });

  it("deletes unreferenced canonical objects (abandoned upload / lost delete)", () => {
    const wp = "wallpapers/murugan/gone.mp4";
    const wp2 = "wallpapers/temples/gone.jpg";
    const out = selectCanonicalKeysToDelete(
      [obj(wp, OLD), obj(wp2, OLD)],
      new Set(["wallpapers/murugan/kept.mp4"]),
      NOW,
    );
    expect(out).toEqual([wp, wp2]);
  });

  it("keeps ringtone audio AND cover keys while a row references them", () => {
    const audio = "ringtones/murugan/abc.mp3";
    const cover = "ringtones/covers/murugan/abc.jpg";
    const out = selectCanonicalKeysToDelete(
      [obj(audio, OLD), obj(cover, OLD)],
      new Set([audio, cover]),
      NOW,
    );
    expect(out).toEqual([]);
  });

  it("deletes unreferenced ringtones/ objects (audio and covers) past the grace window", () => {
    const orphanAudio = "ringtones/sivan/gone.mp3";
    const orphanCover = "ringtones/covers/sivan/gone.jpg";
    const out = selectCanonicalKeysToDelete(
      [obj(orphanAudio, OLD), obj(orphanCover, OLD)],
      new Set(["ringtones/sivan/kept.mp3"]),
      NOW,
    );
    expect(out).toEqual([orphanAudio, orphanCover]);
  });

  it("never deletes fresh ringtones/ objects inside the grace window", () => {
    const out = selectCanonicalKeysToDelete(
      [obj("ringtones/amman/fresh.mp3", FRESH), obj("ringtones/covers/amman/fresh.jpg", FRESH)],
      new Set(),
      NOW,
    );
    expect(out).toEqual([]);
  });

  it("never deletes objects inside the grace window (mid-create CMS upload)", () => {
    const key = "wallpapers/posters/fresh.jpg";
    const out = selectCanonicalKeysToDelete([obj(key, FRESH)], new Set(), NOW);
    expect(out).toEqual([]);
  });

  it("never touches non-canonical prefixes (catalog pages, user submissions)", () => {
    const out = selectCanonicalKeysToDelete(
      [
        obj("catalog/wallpapers/all_1.json", OLD),
        obj("catalog/version.json", OLD),
        obj("user/u1/submissions/1.mp4", OLD),
      ],
      new Set(),
      NOW,
    );
    expect(out).toEqual([]);
  });

  it("partitions a mixed listing correctly", () => {
    const referenced = "wallpapers/sivan/live.mp4";
    const fresh = "wallpapers/amman/fresh.jpg";
    const orphan = "wallpapers/perumal/orphan.jpg";
    const out = selectCanonicalKeysToDelete(
      [obj(referenced, OLD), obj(fresh, FRESH), obj(orphan, OLD)],
      new Set([referenced]),
      NOW,
    );
    expect(out).toEqual([orphan]);
  });
});
