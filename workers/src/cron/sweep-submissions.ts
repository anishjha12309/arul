/**
 * Sweep cron — reclaim orphaned user-submission objects from R2. Approve and reject both delete inline.
 *
 * The inline delete is fire-and-forget in waitUntil -> it can be lost -> this is the backstop
 * A confirm-upload that never landed leaves bytes with NO submission row at all -> only a sweep finds those
 * An object is kept ONLY while it still backs a `pending` row -> everything else is deleted
 * Deletion waits out a grace window -> an upload whose row has not committed yet is never swept
 * Pending rows are not immortal: one past PENDING_EXPIRY_DAYS is auto-rejected FIRST, releasing its object here
 * Without that expiry, a single unmoderated pending row would shield its bytes from reclamation forever
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";

/** An object younger than this is never swept -> an in-flight upload has no row yet -> the grace is what protects it. */
export const SWEEP_GRACE_MS = 6 * 60 * 60 * 1000; // 6 hours

/** Pending submissions older than this are auto-rejected so their bytes free up. */
export const PENDING_EXPIRY_DAYS = 30;

import { SUBMISSION_PREFIX, SUBMISSION_INFIX } from "../lib/r2.js";

export interface SweepCandidate {
  key: string;
  uploadedMs: number;
}

export interface SweepResult {
  scanned: number;
  deleted: number;
  kept: number;
  errors: number;
  /** Pending rows auto-rejected this run for exceeding PENDING_EXPIRY_DAYS. */
  expired: number;
}

/** The delete decision, kept I/O-free -> it is unit-testable without R2 or Neon -> keep every fetch out of it. */
export function selectKeysToDelete(
  candidates: SweepCandidate[],
  pendingKeys: ReadonlySet<string>,
  nowMs: number,
  graceMs: number = SWEEP_GRACE_MS,
): string[] {
  const out: string[] = [];
  for (const c of candidates) {
    if (!c.key.includes(SUBMISSION_INFIX)) continue; // only submission objects
    if (pendingKeys.has(c.key)) continue; // still awaiting moderation — keep
    if (nowMs - c.uploadedMs < graceMs) continue; // too fresh — may be in-flight
    out.push(c.key);
  }
  return out;
}

export async function sweepSubmissions(env: Env): Promise<SweepResult> {
  const sql = getDb(env);
  const result: SweepResult = { scanned: 0, deleted: 0, kept: 0, errors: 0, expired: 0 };

  try {
    // Auto-reject stale pending rows FIRST -> their objects leave the keep-set and are reclaimed in this same run
    // Those objects are already weeks past the grace window -> no second pass is needed
    // The ROW stays -> the user's history and rejected tab still show it
    const expiryReason = `Expired — not reviewed within ${PENDING_EXPIRY_DAYS} days`;
    const expiredRows = (await sql`
      UPDATE content_submissions
      SET status = 'rejected',
          rejection_reason = ${expiryReason}
      WHERE status = 'pending'
        AND created_at < now() - make_interval(days => ${PENDING_EXPIRY_DAYS})
      RETURNING id
    `) as unknown as { id: string }[];
    result.expired = expiredRows.length;
    if (result.expired > 0) {
      console.log(`[sweep-submissions] auto-rejected ${result.expired} expired pending submission(s)`);
    }

    // Still-pending uploads are the ONLY unconditional keeps -> everything else is a leftover
    const pendingRows = (await sql`
      SELECT file_key FROM content_submissions WHERE status = 'pending'
    `) as unknown as { file_key: string }[];
    const pendingKeys = new Set(pendingRows.map((r) => r.file_key));

    const nowMs = Date.now();
    let cursor: string | undefined;

    do {
      const opts: R2ListOptions = { prefix: SUBMISSION_PREFIX, limit: 1000 };
      if (cursor) opts.cursor = cursor;
      const listed = await env.R2.list(opts);
      const subObjects: SweepCandidate[] = listed.objects
        .filter((o) => o.key.includes(SUBMISSION_INFIX))
        .map((o) => ({ key: o.key, uploadedMs: o.uploaded.getTime() }));
      result.scanned += subObjects.length;

      const toDelete = selectKeysToDelete(subObjects, pendingKeys, nowMs);
      result.kept += subObjects.length - toDelete.length;

      for (const key of toDelete) {
        try {
          await env.R2.delete(key);
          result.deleted++;
        } catch (err) {
          result.errors++;
          console.error(`[sweep-submissions] delete failed for ${key}:`, err);
        }
      }

      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

    return result;
  } finally {
    await sql.end();
  }
}
