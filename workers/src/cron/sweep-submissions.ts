/**
 * Sweep cron — reclaim orphaned user-submission objects from R2.
 *
 * Every user upload lands at user/<sub>/submissions/… via a presigned PUT. On
 * approve the bytes are copied to a canonical catalog key; on approve AND reject
 * the original is now deleted inline. This sweep is the backstop for the cases
 * those inline deletes can't cover:
 *   - an inline delete that was lost (fire-and-forget in waitUntil), or
 *   - an upload whose confirm-upload never landed, so NO submission row exists.
 *
 * Rule: an object under user/…/submissions/ is kept ONLY while it still backs a
 * `pending` submission row. Everything else (approved/rejected leftovers, or no
 * row at all) is deleted — but only after a grace window, so an in-flight upload
 * whose row hasn't committed yet is never swept.
 *
 * Pending rows are not immortal: before sweeping, any submission still pending
 * after PENDING_EXPIRY_DAYS is auto-rejected (reason "expired"), which releases
 * its object to this same sweep. Without that, one unmoderated pending row
 * shields its bytes from reclamation forever.
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";

/** Objects younger than this are never swept (protects in-flight uploads). */
export const SWEEP_GRACE_MS = 6 * 60 * 60 * 1000; // 6 hours

/** Pending submissions older than this are auto-rejected so their bytes free up. */
export const PENDING_EXPIRY_DAYS = 30;

const SUBMISSION_PREFIX = "user/";
const SUBMISSION_INFIX = "/submissions/";

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

/**
 * Pure decision: given the submission objects seen, the set of file_keys still
 * backing a pending row, and `now`, return the keys to delete. Kept I/O-free so
 * it can be unit-tested without R2/Neon.
 */
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
    // Auto-reject stale pending rows FIRST, so their objects drop out of the
    // keep-set and are reclaimed in this same run (they are already weeks past
    // the grace window). The row stays for the user's history / rejected tab.
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

    // The only objects worth keeping back unconditionally: still-pending uploads.
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
