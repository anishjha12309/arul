/**
 * Media routes (all gated — require valid access JWT):
 *
 *   POST /media/signed-url     — presigned R2 GET URL for private media (apply gate)
 *   POST /media/upload-url     — presigned R2 PUT URL for user submissions
 *   POST /media/confirm-upload — record a completed upload as a content_submission
 *
 * Key decisions (from architecture.md §3.2):
 *   - Wallpaper full_key + ringtone audio_key are PUBLIC in the catalog (free
 *     preview/stream via CDN). /media/signed-url is only called at apply/set/save
 *     time (write to device).
 *   - ALL content requires premium to apply/set/save (product decision
 *     2026-07-01 — every wallpaper + ringtone is premium). entitlement.isPremium()
 *     is checked live from Neon on every request here — never from the token. This
 *     is a SOFT gate: the public CDN keys mean a determined user could still fetch
 *     raw URLs; acceptable for v1. (The per-row is_premium flag was removed 2026-07-01.)
 *   - This route is also the app's popularity meter: every granted apply/set
 *     increments the row's counter (db/schema/06_popularity.sql), which is what
 *     orders the All chip. It is the only 100%, unsampled, server-side record of
 *     a real use — analytics is a sink, never the source for a sort key.
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { premiumPredicate } from "../lib/entitlement.js";
import { presignGet, presignPut, SUBMISSION_INFIX } from "../lib/r2.js";
import { getDb } from "../lib/db.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
import { MAX_BYTES_BY_MIME as ALLOWED } from "../lib/media-constraints.js";
import { verifyMediaObject } from "../lib/media-verify.js";

// Maps kind → { table, privateKeyCol, popularity counter column }
// Wallpaper full_key is intentionally included (it's the apply gate key).
const KIND_TABLE: Record<
  string,
  { table: string; keyCol: string; countCol: string }
> = {
  wallpaper: { table: "wallpapers", keyCol: "full_key", countCol: "apply_count" },
  ringtone: { table: "ringtones", keyCol: "audio_key", countCol: "set_count" },
};

/**
 * Whether this grant counts toward the row's popularity score (db/schema/06_popularity.sql).
 *
 * A wallpaper reaches this route for BOTH apply and share, so only an explicit
 * `action: 'apply'` counts — otherwise every share would inflate a column named
 * apply_count. A ringtone has no share path (set is its only gated action), so
 * every ringtone grant is a set.
 *
 * A request with NO `action` counts for neither. Builds shipped before this
 * change send none, so they cannot pollute the number while they age out; the
 * install base is small enough that starting the count from the next release
 * loses nothing real.
 */
function countsAsUse(kind: string, action: unknown): boolean {
  if (kind === "ringtone") return true;
  return action === "apply";
}

// ── POST /media/signed-url ───────────────────────────────────────────────────

export async function handleSignedUrl(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // Each grant costs a live Neon entitlement read. Limit is high enough for
  // genuine bulk apply/share bursts, low enough to stop a scripted drain.
  if (!(await allowRequest(env.RL_MEDIA, `signed:${sub}`))) {
    console.warn(`[media/signed-url] rate limited user ${sub}`);
    return tooManyRequests();
  }

  let body: { id?: string; kind?: string; action?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { id, kind, action } = body;
  if (!id || typeof id !== "string" || !id.trim()) {
    return errorResponse(400, "missing_field", "id is required");
  }
  if (!kind || !KIND_TABLE[kind]) {
    return errorResponse(
      400,
      "invalid_kind",
      "kind must be one of: wallpaper, ringtone",
    );
  }

  const { table, keyCol, countCol } = KIND_TABLE[kind];
  const sql = getDb(env);

  // Background work this request must finish before the connection closes, but
  // that the CALLER must never wait on. This is the app's most latency-sensitive
  // route (the comment below describes collapsing two round-trips into one for
  // exactly that reason), so the popularity increment rides here instead of on
  // the response path. Chaining sql.end() off this in the `finally` is what
  // stops the connection being torn down mid-UPDATE — scheduling both as
  // independent waitUntil() calls leaves their order undefined.
  let tail: Promise<unknown> = Promise.resolve();

  try {
    // Content key + entitlement in ONE round-trip.
    //
    // These used to be two sequential awaits, so every gated apply/set/share
    // paid two Hyperdrive round-trips back to back — on the hot path for the
    // app's most latency-sensitive action. They are independent reads, so the
    // DB can answer both in a single statement. The premium half is the shared
    // fragment from entitlement.ts, NOT a local copy: entitlement is still read
    // live from Neon on every call, so a refund or expiry applies immediately.
    const rows = await sql`
      SELECT
        (
          SELECT ${sql(keyCol)}
          FROM ${sql(table)}
          WHERE id = ${id}
            AND is_published = true
          LIMIT 1
        ) AS private_key,
        ${premiumPredicate(sql, sub)} AS is_premium
    `;

    const privateKey = rows[0]?.private_key as string | null | undefined;
    if (!privateKey) {
      return errorResponse(404, "not_found", "Content not found");
    }

    // ALL content is premium — every wallpaper + ringtone apply/set/share needs
    // a subscription (there is no per-row flag and no test allow-list bypass).
    // Browse/preview stay free: they read the public CDN keys directly and
    // never reach this route.
    if (rows[0]?.is_premium !== true) {
      return errorResponse(403, "premium_required", "Premium subscription required");
    }

    // Popularity counter — AFTER the entitlement check, so the number only ever
    // reflects grants we actually made. Fired without await: it runs alongside
    // presignGet and is drained by the `finally` below. A failed increment is
    // logged and swallowed — a sort key must never cost someone their wallpaper.
    if (countsAsUse(kind, action)) {
      tail = sql`
        UPDATE ${sql(table)}
        SET ${sql(countCol)} = ${sql(countCol)} + 1
        WHERE id = ${id}
      `.catch((err: unknown) => {
        console.error(`[media/signed-url] ${countCol} increment failed:`, err);
      });
    }

    const url = await presignGet(env, privateKey, 300);
    return c.json({ url, expiresIn: 300 });
  } catch (err) {
    console.error("[media/signed-url] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    // `tail` never rejects (the increment catches its own error), so this always
    // reaches sql.end().
    c.executionCtx.waitUntil(tail.then(() => sql.end()));
  }
}

// ── POST /media/upload-url ───────────────────────────────────────────────────

export async function handleUploadUrl(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: { key?: string; contentType?: string; size?: number };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { key, contentType, size } = body;

  if (!key || typeof key !== "string" || !key.trim()) {
    return errorResponse(400, "bad_key", "key is required");
  }
  if (!contentType || typeof contentType !== "string") {
    return errorResponse(400, "bad_type", "contentType is required");
  }

  // Enforce key prefix to caller's own user/ namespace
  const allowedPrefix = `user/${sub}/`;
  if (!key.startsWith(allowedPrefix)) {
    return errorResponse(
      400,
      "bad_key",
      `key must start with user/<your-id>/`,
    );
  }
  if (!key.includes(SUBMISSION_INFIX)) {
    return errorResponse(
      400,
      "bad_key",
      `key must be under user/<your-id>/submissions/`,
    );
  }

  const maxBytes = ALLOWED[contentType];
  if (maxBytes === undefined) {
    return errorResponse(400, "bad_type", `File type not allowed: ${contentType}`);
  }
  if (typeof size === "number" && size > maxBytes) {
    const mb = Math.round(maxBytes / (1024 * 1024));
    return errorResponse(400, "too_large", `File too large. Max is ${mb}MB for this type`);
  }

  try {
    const uploadUrl = await presignPut(env, key, contentType, 300);
    const cdnBase = env.R2_CDN_BASE_URL.replace(/\/$/, "");
    const publicUrl = `${cdnBase}/${key}`;
    return c.json({ uploadUrl, publicUrl });
  } catch (err) {
    console.error("[media/upload-url] presign error:", err);
    return errorResponse(500, "server_error", "Failed to generate upload URL");
  }
}

// ── POST /media/confirm-upload ───────────────────────────────────────────────

/**
 * Max submissions a user may have awaiting moderation at once. A pending row
 * shields its R2 object from the sweep cron, so without a cap one user could
 * park unlimited bytes in R2 as "pending" forever.
 */
export const MAX_PENDING_SUBMISSIONS = 10;

export async function handleConfirmUpload(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: {
    kind?: string;
    fileKey?: string;
    title?: string;
    category?: string;
  };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { kind, fileKey, title, category } = body;
  // Only kinds the moderation queue can actually publish — anything else would
  // sit pending forever (approve rejects unknown kinds) while pinning its bytes.
  // Both kinds require the CMS's `userUploadKinds` for arul to list them.
  if (kind !== "wallpaper" && kind !== "ringtone") {
    return errorResponse(400, "invalid_kind", "kind must be one of: wallpaper, ringtone");
  }
  if (!fileKey || typeof fileKey !== "string") {
    return errorResponse(400, "missing_field", "fileKey is required");
  }
  // Enforce key still belongs to this user
  if (!fileKey.startsWith(`user/${sub}/`)) {
    return errorResponse(400, "bad_key", "fileKey must be under your user/ prefix");
  }
  if (!fileKey.includes(SUBMISSION_INFIX)) {
    return errorResponse(400, "bad_key", "fileKey must be under your submissions/ prefix");
  }

  // The upload must have actually landed AND pass byte-level QC (magic bytes
  // match the signed content-type, image dimensions in range, live-wallpaper
  // mp4s in the hw-decoder-safe geometry / H.264, ringtones real audio with no
  // video track). A failing object is auto-rejected: it is deleted immediately,
  // no submission row is created, and the response carries the reason for the
  // app to show the user. The role is the SUBMITTED kind — passing a constant
  // here would QC an audio upload against the wallpaper rules and reject every
  // ringtone as "not a JPEG/PNG/WebP image or MP4".
  const qc = await verifyMediaObject(env.R2, fileKey, kind);
  if (!qc.ok) {
    if (qc.code === "not_found") {
      return errorResponse(400, "not_uploaded", "Upload not found — complete the upload first");
    }
    console.warn(`[media/confirm-upload] QC rejected ${fileKey}: ${qc.code} — ${qc.message}`);
    c.executionCtx.waitUntil(env.R2.delete(fileKey).catch(() => {}));
    return errorResponse(400, qc.code, qc.message);
  }

  const sql = getDb(env);
  try {
    const pending = await sql`
      SELECT count(*)::int AS n FROM content_submissions
      WHERE user_id = ${sub} AND status = 'pending'
    `;
    const pendingCount = Number(pending[0]?.n ?? 0);
    if (pendingCount >= MAX_PENDING_SUBMISSIONS) {
      return errorResponse(
        429,
        "too_many_pending",
        `You already have ${MAX_PENDING_SUBMISSIONS} submissions awaiting review — please wait for moderation`,
      );
    }

    // One object = one submission row. A retried confirm (double-tap, network
    // retry) hits the unique file_key index and gets the existing row back, so
    // one upload can never become multiple pending rows / duplicate catalog
    // copies on approval.
    const rows = await sql`
      INSERT INTO content_submissions (user_id, kind, file_key, title, category, status)
      VALUES (${sub}, ${kind}, ${fileKey}, ${title ?? null}, ${category ?? null}, 'pending')
      ON CONFLICT (file_key) DO UPDATE SET file_key = EXCLUDED.file_key
      RETURNING id, status
    `;

    const row = rows[0];
    return c.json({ id: row.id as string, status: row.status as string });
  } catch (err) {
    console.error("[media/confirm-upload] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

/** Extract and verify the Bearer access token; return sub or null. */
async function requireAuth(c: Context<{ Bindings: Env }>): Promise<string | null> {
  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const claims = await verifyAccessToken(token, c.env.JWT_SECRET);
    return claims.sub;
  } catch {
    return null;
  }
}

function errorResponse(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}
