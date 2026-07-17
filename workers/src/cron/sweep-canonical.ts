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

/** The only prefixes this sweep manages. */
export const CANONICAL_PREFIXES = ["wallpapers/", "ringtones/"] as const;

export interface CanonicalCandidate {
  key: string;
  uploadedMs: number;
}

export interface CanonicalSweepResult {
  scanned: number;
  deleted: number;
  kept: number;
  errors: number;
  /** True when deletion was skipped because the DB reported zero rows (failsafe). */
  aborted: boolean;
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
): string[] {
  const out: string[] = [];
  for (const c of candidates) {
    if (!CANONICAL_PREFIXES.some((p) => c.key.startsWith(p))) continue; // canonical only
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
    const referenced = new Set<string>([
      ...wpRows.map((r) => r.full_key),
      ...rtRows.map((r) => r.audio_key),
      ...rtRows.map((r) => r.cover_key).filter((k): k is string => !!k),
    ]);

    // Failsafe: an empty reference set would mark EVERY object for deletion.
    // All tables empty is far more likely a DB/config fault than a real state
    // (the catalog has shipped content) — refuse to sweep rather than risk
    // wiping the whole media store.
    if (referenced.size === 0) {
      console.warn("[sweep-canonical] 0 referenced keys in DB — aborting sweep (failsafe)");
      result.aborted = true;
      return result;
    }

    const nowMs = Date.now();
    for (const prefix of CANONICAL_PREFIXES) {
      let cursor: string | undefined;
      do {
        const opts: R2ListOptions = { prefix, limit: 1000 };
        if (cursor) opts.cursor = cursor;
        const listed = await env.R2.list(opts);
        const candidates: CanonicalCandidate[] = listed.objects.map((o) => ({
          key: o.key,
          uploadedMs: o.uploaded.getTime(),
        }));
        result.scanned += candidates.length;

        const toDelete = selectCanonicalKeysToDelete(candidates, referenced, nowMs);
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

        cursor = listed.truncated ? listed.cursor : undefined;
      } while (cursor);
    }

    return result;
  } finally {
    await sql.end();
  }
}
