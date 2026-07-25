/**
 * Canonical-media sweep cron — reclaim orphaned catalog objects from R2.
 *
 * Canonical media lives at wallpapers/<category>/…, ringtones/<category>/…
 * and ringtones/covers/<category>/…
 * Two flows can strand an object there with no DB row referencing it:
 *   - a CMS upload (presigned PUT lands the bytes BEFORE the row insert) whose
 *     form was abandoned, so the row never got created, or
 *   - a delete/replace whose old-object cleanup was skipped (rebuild failed) or
 *     lost (fire-and-forget waitUntil) — the row is gone but the bytes remain.
 * Neither is ever retried inline, so without this sweep those objects (a live
 * wallpaper can be tens of MB) accumulate forever.
 *
 * Rule: an object under wallpapers/ or ringtones/ is kept ONLY while some row
 * (published or not) references it as full_key / audio_key / cover_key. Everything else is
 * deleted — but only after a grace window, so a CMS upload whose row hasn't been
 * saved yet is never swept mid-edit. catalog/ and user/ prefixes are never touched.
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";

/** Objects younger than this are never swept (protects in-progress CMS creates). */
export const CANONICAL_GRACE_MS = 12 * 60 * 60 * 1000; // 12 hours

/**
 * The only prefixes this sweep manages.
 *
 * `thumbs/` is included even though NO DB column stores a thumb key: a live
 * wallpaper's poster key is DERIVED from its full_key (see thumbKeyFor). It
 * lives at top level rather than under wallpapers/ precisely so this sweep
 * couldn't see it as an orphan — but the consequence was that nothing reclaimed
 * it either. Thumb cleanup was CMS-inline fire-and-forget only, so every lost
 * delete leaked forever. Deriving the expected set closes that.
 */
export const CANONICAL_PREFIXES = ["wallpapers/", "ringtones/", "thumbs/"] as const;

/**
 * Blast-radius cap. A sweep that wants to delete MORE than this fraction of a
 * prefix's objects is treated as evidence the reference set is wrong (a failed
 * migration, a partial query result, a renamed column) rather than as a real
 * cleanup, and the whole prefix is skipped.
 *
 * WHY a fraction and not just "is the set empty": the old guard only aborted
 * when EVERY table came back empty, because it merged wallpaper + ringtone keys
 * into one set. If only `wallpapers` returned zero rows, the ringtone keys kept
 * the set non-empty, the guard passed, and every wallpaper object — the entire
 * media library, with no R2 versioning to undo it — was deleted. Reference sets
 * are now per-prefix (below) AND capped here.
 */
export const MAX_DELETE_FRACTION = 0.34;

/**
 * Deletions at or below this count always proceed regardless of the fraction —
 * without it, a nearly-empty prefix (3 objects, 2 orphaned = 67%) could never
 * be swept at all.
 */
export const DELETE_FRACTION_FLOOR = 25;

/**
 * Arul: "wallpapers/<category>/<stem>.<ext>" → "thumbs/<category>/<stem>.jpg".
 *
 * Deliberately maps STATIC keys too, not just mp4s. Only live videos actually
 * get a poster captured (the CMS presigns a thumb only for video/mp4), so the
 * extra entries name objects that don't exist — which is harmless. Being
 * over-inclusive here is the safe direction for a DELETE decision: it can only
 * ever protect more, never less. Must stay in sync with arulThumbKey() in the
 * CMS registry (c:\Anish\Unified CMS\src\registry.ts).
 */
export function thumbKeyFor(fullKey: string): string | null {
  const m = /^wallpapers\/([^/]+)\/([^/]+)$/.exec(fullKey);
  if (!m) return null;
  const stem = m[2]!.replace(/\.[^.]+$/, "");
  return `thumbs/${m[1]}/${stem}.jpg`;
}

export interface CanonicalCandidate {
  key: string;
  uploadedMs: number;
}

export interface CanonicalSweepResult {
  scanned: number;
  deleted: number;
  kept: number;
  errors: number;
  /** True when ANY prefix refused to sweep (empty reference set or blast-radius cap). */
  aborted: boolean;
  /** Per-prefix reason for a refusal, for the cron log / operator triage. */
  abortedPrefixes: Record<string, string>;
}

/**
 * Blast-radius decision, kept pure so it is unit-testable without R2/Neon.
 * Returns null when the deletion set is safe to execute, or a human-readable
 * reason when it must be refused.
 */
export function blastRadiusRefusal(
  deleteCount: number,
  scannedCount: number,
  maxFraction: number = MAX_DELETE_FRACTION,
  floor: number = DELETE_FRACTION_FLOOR,
): string | null {
  if (deleteCount <= floor) return null;
  if (scannedCount <= 0) return null;
  const fraction = deleteCount / scannedCount;
  if (fraction <= maxFraction) return null;
  return (
    `would delete ${deleteCount}/${scannedCount} objects ` +
    `(${(fraction * 100).toFixed(1)}% > ${(maxFraction * 100).toFixed(0)}% cap)`
  );
}

/**
 * Pure decision: given the canonical objects seen, the set of keys referenced by
 * DB rows, and `now`, return the keys to delete. Kept I/O-free so it can be
 * unit-tested without R2/Neon.
 */
export function selectCanonicalKeysToDelete(
  candidates: CanonicalCandidate[],
  referencedKeys: ReadonlySet<string>,
  nowMs: number,
  graceMs: number = CANONICAL_GRACE_MS,
  /**
   * The prefix currently being swept. When given, ONLY keys under it are
   * considered — `referencedKeys` is now a per-prefix set, so judging a key
   * from a different prefix against it would delete an object whose own
   * table was never consulted. Omitted = legacy "any canonical prefix" check.
   */
  activePrefix?: string,
): string[] {
  const out: string[] = [];
  for (const c of candidates) {
    if (activePrefix !== undefined) {
      if (!c.key.startsWith(activePrefix)) continue; // not this prefix's business
    } else if (!CANONICAL_PREFIXES.some((p) => c.key.startsWith(p))) {
      continue; // canonical only
    }
    if (referencedKeys.has(c.key)) continue; // a row still points here — keep
    if (nowMs - c.uploadedMs < graceMs) continue; // too fresh — may be mid-create
    out.push(c.key);
  }
  return out;
}

export async function sweepCanonical(env: Env): Promise<CanonicalSweepResult> {
  const sql = getDb(env);
  const result: CanonicalSweepResult = {
    scanned: 0,
    deleted: 0,
    kept: 0,
    errors: 0,
    aborted: false,
    abortedPrefixes: {},
  };

  try {
    // EVERY row keeps its object — drafts included; publish state is irrelevant
    // here (an unpublished row's media must survive to be re-published).
    const wpRows = (await sql`SELECT full_key FROM wallpapers`) as unknown as {
      full_key: string;
    }[];
    // Ringtones reference TWO objects per row: the audio file and the (nullable)
    // cover image. Both must survive the sweep while the row exists — a swept
    // cover would leave every published ringtone with a broken artwork tile.
    const rtRows = (await sql`SELECT audio_key, cover_key FROM ringtones`) as unknown as {
      audio_key: string;
      cover_key: string | null;
    }[];
    // Reference sets are kept PER PREFIX, never merged: `wallpapers/` objects
    // may only be justified by wallpaper rows and `ringtones/` objects only by
    // ringtone rows. Merging them is what let one table's rows vouch for the
    // other table's objects (see MAX_DELETE_FRACTION).
    const wallpaperKeys = wpRows.map((r) => r.full_key).filter(Boolean);
    const referencedByPrefix: Record<string, Set<string>> = {
      "wallpapers/": new Set(wallpaperKeys),
      // Ringtone covers live at ringtones/covers/<category>/… so they belong to
      // this prefix's set alongside the audio files.
      "ringtones/": new Set([
        ...rtRows.map((r) => r.audio_key).filter(Boolean),
        ...rtRows.map((r) => r.cover_key).filter((k): k is string => !!k),
      ]),
      // Derived, not stored — one expected poster per wallpaper.
      "thumbs/": new Set(
        wallpaperKeys
          .map((k) => thumbKeyFor(k))
          .filter((k): k is string => k !== null),
      ),
    };

    const nowMs = Date.now();
    for (const prefix of CANONICAL_PREFIXES) {
      const referenced = referencedByPrefix[prefix] ?? new Set<string>();

      // Failsafe 1: an empty reference set marks EVERY object under this prefix
      // for deletion. A shipped catalog never legitimately has zero rows, so
      // treat it as a DB/config fault and refuse.
      if (referenced.size === 0) {
        const reason = "0 referenced keys for this prefix in DB";
        console.error(`[sweep-canonical] ABORT ${prefix} — ${reason} (failsafe)`);
        result.aborted = true;
        result.abortedPrefixes[prefix] = reason;
        continue;
      }

      // Collect the whole prefix BEFORE deleting anything: the blast-radius cap
      // is a property of the prefix as a whole, and the old page-at-a-time loop
      // had already deleted earlier pages by the time a problem was visible.
      const candidates: CanonicalCandidate[] = [];
      let cursor: string | undefined;
      do {
        const opts: R2ListOptions = { prefix, limit: 1000 };
        if (cursor) opts.cursor = cursor;
        const listed = await env.R2.list(opts);
        for (const o of listed.objects) {
          candidates.push({ key: o.key, uploadedMs: o.uploaded.getTime() });
        }
        cursor = listed.truncated ? listed.cursor : undefined;
      } while (cursor);

      result.scanned += candidates.length;

      const toDelete = selectCanonicalKeysToDelete(
        candidates,
        referenced,
        nowMs,
        CANONICAL_GRACE_MS,
        prefix,
      );

      // Failsafe 2: blast-radius cap.
      const refusal = blastRadiusRefusal(toDelete.length, candidates.length);
      if (refusal !== null) {
        console.error(`[sweep-canonical] ABORT ${prefix} — ${refusal} (failsafe)`);
        result.aborted = true;
        result.abortedPrefixes[prefix] = refusal;
        result.kept += candidates.length;
        continue;
      }

      result.kept += candidates.length - toDelete.length;

      for (const key of toDelete) {
        try {
          await env.R2.delete(key);
          result.deleted++;
          console.log(`[sweep-canonical] deleted orphan ${key}`);
        } catch (err) {
          result.errors++;
          console.error(`[sweep-canonical] delete failed for ${key}:`, err);
        }
      }
    }

    return result;
  } finally {
    await sql.end();
  }
}
