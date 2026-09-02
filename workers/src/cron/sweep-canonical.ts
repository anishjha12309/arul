/**
 * Canonical-media sweep cron — reclaim orphaned catalog objects from R2.
 *
 * A CMS presigned PUT lands the bytes BEFORE the row insert -> an abandoned form strands them with no row
 * A delete/replace whose old-object cleanup failed or was lost leaves the bytes with the row gone
 * Neither is retried inline -> without this sweep a tens-of-MB live wallpaper accumulates forever
 * An object is kept ONLY while a row references it as full_key / audio_key / cover_key -> draft rows count too
 * Deletion waits out a grace window -> a CMS upload whose row is not saved yet is never swept mid-edit
 * catalog/ and user/ are never touched -> only CANONICAL_PREFIXES are this cron's business
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";

/** An object younger than this is never swept -> an in-progress CMS create has no row yet -> the grace protects it. */
export const CANONICAL_GRACE_MS = 12 * 60 * 60 * 1000; // 12 hours

/**
 * The only prefixes this sweep manages.
 *
 * No DB column stores a thumb key -> a poster key is DERIVED from full_key (thumbKeyFor) -> and the bucket is ours alone
 * `thumbs/` sits at top level so this sweep could not mistake a poster for an orphan -> but nothing reclaimed it either
 * Thumb cleanup was CMS-inline fire-and-forget only -> every lost delete leaked forever -> derive the set instead
 */
export const CANONICAL_PREFIXES = ["wallpapers/", "ringtones/", "thumbs/"] as const;

/**
 * Blast-radius cap — wanting to delete more than this fraction of a prefix means the REFERENCE SET is wrong.
 *
 * A failed migration, a partial query result or a renamed column all look like a huge legitimate cleanup
 * So the whole prefix is skipped instead -> a wrong set must cost a missed sweep, never the library
 * "Is the set empty" alone was not enough: a merged wallpaper+ringtone set stayed non-empty when one table returned zero
 * The guard then passed and every wallpaper object was deleted -> R2 has no versioning to undo that
 */
export const MAX_DELETE_FRACTION = 0.34;

/** At or below this count the fraction is ignored -> a nearly-empty prefix (2 orphans of 3 = 67%) could never sweep. */
export const DELETE_FRACTION_FLOOR = 25;

/**
 * "wallpapers/<category>/<stem>.<ext>" -> "thumbs/<category>/<stem>.jpg".
 *
 * Maps STATIC keys too, deliberately -> only live videos get a poster -> the extra names point at nothing, harmlessly
 * Over-inclusive is the SAFE direction for a delete decision -> it can only ever protect more, never less
 * Must stay in sync with arulThumbKey() in the CMS registry (c:\Anish\Unified CMS\src\registry.ts)
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
  /** True when ANY prefix refused to sweep — an empty reference set or the blast-radius cap. */
  aborted: boolean;
  /** Per-prefix refusal reason -> it reaches the cron log -> that log is the operator's only triage surface. */
  abortedPrefixes: Record<string, string>;
}

/** Null = safe to execute; a string = the human-readable refusal. Kept pure so it tests without R2 or Neon. */
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

/** The delete decision, kept I/O-free -> it is unit-testable without R2 or Neon -> keep every fetch out of it. */
export function selectCanonicalKeysToDelete(
  candidates: CanonicalCandidate[],
  referencedKeys: ReadonlySet<string>,
  nowMs: number,
  graceMs: number = CANONICAL_GRACE_MS,
  /**
   * The prefix being swept. Given -> ONLY keys under it are judged, because `referencedKeys` is a PER-PREFIX set.
   * Judging another prefix's key against it would delete an object whose own table was never consulted
   * Omitted -> the legacy "any canonical prefix" check
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
    // EVERY row keeps its object, drafts included -> an unpublished row's media must survive to be published later
    const wpRows = (await sql`SELECT full_key FROM wallpapers`) as unknown as {
      full_key: string;
    }[];
    // A ringtone row references TWO objects: its audio file and a nullable cover -> both must survive the row
    // A swept cover would leave a published ringtone with a broken artwork tile -> select both columns
    const rtRows = (await sql`SELECT audio_key, cover_key FROM ringtones`) as unknown as {
      audio_key: string;
      cover_key: string | null;
    }[];
    // Reference sets stay PER PREFIX, never merged -> a `wallpapers/` object may only be justified by a wallpaper row
    // Merging them is exactly what let one table's rows vouch for the other table's objects (see MAX_DELETE_FRACTION)
    const wallpaperKeys = wpRows.map((r) => r.full_key).filter(Boolean);
    const referencedByPrefix: Record<string, Set<string>> = {
      "wallpapers/": new Set(wallpaperKeys),
      // Ringtone covers live at ringtones/covers/<category>/… -> same prefix as the audio -> same reference set
      "ringtones/": new Set([
        ...rtRows.map((r) => r.audio_key).filter(Boolean),
        ...rtRows.map((r) => r.cover_key).filter((k): k is string => !!k),
      ]),
      // Derived, never stored -> one expected poster per wallpaper -> this set IS the only thing protecting them
      "thumbs/": new Set(
        wallpaperKeys
          .map((k) => thumbKeyFor(k))
          .filter((k): k is string => k !== null),
      ),
    };

    const nowMs = Date.now();
    for (const prefix of CANONICAL_PREFIXES) {
      const referenced = referencedByPrefix[prefix] ?? new Set<string>();

      // Failsafe 1: an empty reference set marks EVERY object under this prefix for deletion
      // A shipped catalog never legitimately has zero rows -> read it as a DB/config fault -> refuse the prefix
      if (referenced.size === 0) {
        const reason = "0 referenced keys for this prefix in DB";
        console.error(`[sweep-canonical] ABORT ${prefix} — ${reason} (failsafe)`);
        result.aborted = true;
        result.abortedPrefixes[prefix] = reason;
        continue;
      }

      // Collect the WHOLE prefix before deleting anything -> the blast-radius cap is a property of the prefix
      // A page-at-a-time loop had already deleted earlier pages by the time the problem became visible
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
