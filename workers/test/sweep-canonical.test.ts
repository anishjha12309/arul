/**
 * The canonical-media sweep DECISION logic.
 * sweepCanonical() needs a live DB and R2 binding -> only the pure `selectCanonicalKeysToDelete` core is testable here
 */

import { describe, it, expect, vi } from "vitest";
import {
  selectCanonicalKeysToDelete,
  blastRadiusRefusal,
  CANONICAL_GRACE_MS,
  MAX_DELETE_FRACTION,
  DELETE_FRACTION_FLOOR,
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

// ── Blast-radius cap ─────────────────────────────────────────────────────────

describe("blastRadiusRefusal", () => {
  it("allows small deletions unconditionally (floor)", () => {
    // 3 of 3 objects is 100% but under the floor -> a tiny prefix must stay sweepable, or it never reclaims anything
    expect(blastRadiusRefusal(3, 3)).toBeNull();
    expect(blastRadiusRefusal(DELETE_FRACTION_FLOOR, DELETE_FRACTION_FLOOR)).toBeNull();
  });

  it("allows a large deletion that is a small share of the prefix", () => {
    expect(blastRadiusRefusal(100, 1000)).toBeNull(); // 10%
  });

  it("REFUSES a wipe-everything sweep", () => {
    const reason = blastRadiusRefusal(111, 111);
    expect(reason).not.toBeNull();
    expect(reason).toContain("111/111");
  });

  it("refuses just above the fraction cap and allows just below", () => {
    const scanned = 1000;
    const justOver = Math.floor(scanned * MAX_DELETE_FRACTION) + 1;
    const justUnder = Math.floor(scanned * MAX_DELETE_FRACTION);
    expect(blastRadiusRefusal(justOver, scanned)).not.toBeNull();
    expect(blastRadiusRefusal(justUnder, scanned)).toBeNull();
  });

  it("never refuses when nothing was scanned", () => {
    expect(blastRadiusRefusal(0, 0)).toBeNull();
  });
});

// ── sweepCanonical: per-prefix reference sets ────────────────────────────────
// The regression this guards: reference sets used to be MERGED across both tables
// If `wallpapers` returned zero rows, the ringtone keys kept that merged set non-empty
// The old "is it empty?" guard then passed and every wallpaper object was deleted
// R2 has no versioning -> that loss is permanent -> this suite is the only thing standing in front of it

describe("sweepCanonical — per-prefix failsafes", () => {
  function makeR2(objectsByPrefix: Record<string, string[]>) {
    const deleted: string[] = [];
    const uploaded = new Date(NOW - CANONICAL_GRACE_MS - 60_000);
    return {
      deleted,
      bucket: {
        list: vi.fn(async (opts: { prefix: string }) => ({
          objects: (objectsByPrefix[opts.prefix] ?? []).map((key) => ({
            key,
            uploaded,
          })),
          truncated: false,
          cursor: undefined,
        })),
        delete: vi.fn(async (key: string) => {
          deleted.push(key);
        }),
      } as unknown as R2Bucket,
    };
  }

  /** The sql mock answers the wallpapers query FIRST, then ringtones -> that order matches sweepCanonical's. */
  function makeSql(wallpaperKeys: string[], ringtoneKeys: string[]) {
    let call = 0;
    const fn = vi.fn(() => {
      call += 1;
      return Promise.resolve(
        call === 1
          ? wallpaperKeys.map((full_key) => ({ full_key }))
          : ringtoneKeys.map((audio_key) => ({ audio_key, cover_key: null })),
      );
    });
    return Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  }

  async function run(
    wallpaperKeys: string[],
    ringtoneKeys: string[],
    objectsByPrefix: Record<string, string[]>,
  ) {
    const sql = makeSql(wallpaperKeys, ringtoneKeys);
    vi.doMock("../src/lib/db.js", () => ({ getDb: () => sql }));
    vi.resetModules();
    const { sweepCanonical } = await import("../src/cron/sweep-canonical.js");
    const r2 = makeR2(objectsByPrefix);
    const result = await sweepCanonical({ R2: r2.bucket } as never);
    return { result, deleted: r2.deleted };
  }

  it("an empty wallpapers table can NOT authorize deleting wallpaper objects", async () => {
    const { result, deleted } = await run(
      [], // wallpapers table came back empty — the fault condition
      ["ringtones/murugan/a.mp3"], // ringtones still populated
      {
        "wallpapers/": [
          "wallpapers/murugan/1.mp4",
          "wallpapers/sivan/2.mp4",
          "wallpapers/amman/3.mp4",
        ],
        "ringtones/": ["ringtones/murugan/a.mp3"],
      },
    );

    expect(deleted).toEqual([]); // nothing lost
    expect(result.aborted).toBe(true);
    expect(result.abortedPrefixes["wallpapers/"]).toContain("0 referenced keys");
    // The healthy prefix still sweeps normally -> one prefix aborting must not stop the others
    expect(result.abortedPrefixes["ringtones/"]).toBeUndefined();
  });

  it("refuses a prefix whose deletions exceed the blast-radius cap", async () => {
    // 1 of 40 wallpaper objects is still referenced -> 39/40 would be deleted -> far past the cap, so refuse
    const objects = Array.from({ length: 40 }, (_, i) => `wallpapers/murugan/${i}.mp4`);
    const { result, deleted } = await run(
      ["wallpapers/murugan/0.mp4"],
      ["ringtones/murugan/a.mp3"],
      { "wallpapers/": objects, "ringtones/": ["ringtones/murugan/a.mp3"] },
    );

    expect(deleted).toEqual([]);
    expect(result.aborted).toBe(true);
    expect(result.abortedPrefixes["wallpapers/"]).toContain("39/40");
    expect(result.kept).toBeGreaterThanOrEqual(40);
  });

  it("still reclaims genuine orphans in the normal case", async () => {
    const referenced = Array.from({ length: 30 }, (_, i) => `wallpapers/murugan/${i}.mp4`);
    const { result, deleted } = await run(
      referenced,
      ["ringtones/murugan/a.mp3"],
      {
        "wallpapers/": [...referenced, "wallpapers/murugan/orphan.mp4"],
        "ringtones/": ["ringtones/murugan/a.mp3", "ringtones/sivan/orphan.mp3"],
      },
    );

    expect(deleted.sort()).toEqual(
      ["ringtones/sivan/orphan.mp3", "wallpapers/murugan/orphan.mp4"].sort(),
    );
    expect(result.aborted).toBe(false);
    expect(result.deleted).toBe(2);
  });

  it("a ringtone row can never vouch for a wallpaper object", async () => {
    // Both tables are populated, but the object under wallpapers/ matches only a RINGTONE key
    const { deleted } = await run(
      ["wallpapers/murugan/kept.mp4"],
      ["ringtones/murugan/a.mp3"],
      {
        "wallpapers/": ["wallpapers/murugan/kept.mp4", "ringtones/murugan/a.mp3"],
        "ringtones/": ["ringtones/murugan/a.mp3"],
      },
    );
    // The ringtones table does not protect it -> but it is not under a prefix it belongs to either
    // selectCanonicalKeysToDelete's prefix check keeps it out of scope -> a cross-table key is never judged
    expect(deleted).toEqual([]);
  });
});
