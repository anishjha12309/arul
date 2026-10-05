import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { premiumPredicate } from "../lib/entitlement.js";
import { presignGet, presignPut, SUBMISSION_INFIX } from "../lib/r2.js";
import { getDb } from "../lib/db.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
import { MAX_BYTES_BY_MIME as ALLOWED } from "../lib/media-constraints.js";
import { verifyMediaObject } from "../lib/media-verify.js";

/**
 * `counterFor` names the popularity column this grant bumps, or null for none.
 *
 * A wallpaper reaches this route for BOTH apply and share -> only an explicit `action: 'apply'` counts
 * Otherwise every share would inflate a column named apply_count -> the number would stop meaning "applied"
 * A ringtone has no share path -> set is its only gated action -> every ringtone grant is a set
 * A status keeps share and save apart -> each action bumps its own column; the feed orders on their sum
 * A request with NO `action` counts for none of them -> older builds send none and cannot pollute the number
 */
const KIND_TABLE: Record<
  string,
  { table: string; keyCol: string; counterFor: (action: unknown) => string | null }
> = {
  wallpaper: {
    table: "wallpapers",
    keyCol: "full_key",
    counterFor: (action) => (action === "apply" ? "apply_count" : null),
  },
  ringtone: {
    table: "ringtones",
    keyCol: "audio_key",
    counterFor: () => "set_count",
  },
  status: {
    table: "statuses",
    keyCol: "full_key",
    counterFor: (action) =>
      action === "share" ? "share_count" : action === "download" ? "download_count" : null,
  },
};

export async function handleSignedUrl(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  // Each grant costs a live Neon entitlement read -> high enough for a real bulk apply burst, low enough to stop a drain
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
    return errorResponse(400, "invalid_kind", "kind must be one of: wallpaper, ringtone, status");
  }

  const { table, keyCol, counterFor } = KIND_TABLE[kind];
  const countCol = counterFor(action);
  const sql = getDb(env);

  // This is the app's most latency-sensitive route -> the popularity increment rides here, not on the response path
  let tail: Promise<unknown> = Promise.resolve();

  try {
    // Content key + entitlement in ONE round-trip -> two sequential awaits paid two Hyperdrive trips back to back
    // They are independent reads -> the DB answers both in a single statement -> on the hot path that halves it
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

    if (rows[0]?.is_premium !== true) {
      return errorResponse(403, "premium_required", "Premium subscription required");
    }

    // Popularity — AFTER the entitlement check -> the number only ever reflects grants we actually made
    // Fired without await -> it runs alongside presignGet and is drained by the `finally` below
    // A failed write is logged and swallowed -> a sort key must never cost someone their wallpaper
    // ONE counter, ONE increment -> the lifetime total the CMS shows and the feed's ORDER BY reads
    if (countCol !== null) {
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
    // `tail` never rejects -> the increment catches its own error -> this always reaches sql.end()
    c.executionCtx.waitUntil(tail.then(() => sql.end()));
  }
}

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

  // The key must sit under the CALLER's own user/ namespace -> a presign is otherwise a write into anyone's prefix
  const allowedPrefix = `user/${sub}/`;
  if (!key.startsWith(allowedPrefix)) {
    return errorResponse(400, "bad_key", `key must start with user/<your-id>/`);
  }
  if (!key.includes(SUBMISSION_INFIX)) {
    return errorResponse(400, "bad_key", `key must be under user/<your-id>/submissions/`);
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

/** A pending row shields its R2 object from the sweep -> without this cap one user parks unlimited bytes forever. */
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
  // Only kinds the moderation queue can actually publish -> approve rejects an unknown kind
  // Such a row would sit pending forever while pinning its bytes -> the CMS's `userUploadKinds` must list both
  if (kind !== "wallpaper" && kind !== "ringtone") {
    return errorResponse(400, "invalid_kind", "kind must be one of: wallpaper, ringtone");
  }
  if (!fileKey || typeof fileKey !== "string") {
    return errorResponse(400, "missing_field", "fileKey is required");
  }
  // Re-check the key belongs to THIS user -> the presign and the confirm are separate requests
  if (!fileKey.startsWith(`user/${sub}/`)) {
    return errorResponse(400, "bad_key", "fileKey must be under your user/ prefix");
  }
  if (!fileKey.includes(SUBMISSION_INFIX)) {
    return errorResponse(400, "bad_key", "fileKey must be under your submissions/ prefix");
  }

  // The upload must have LANDED and pass byte-level QC -> a signed PUT only ever checked the CLAIMED type and size
  // A failing object is auto-rejected -> deleted immediately, no submission row, and the reason is returned to the app
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

    // One object = one submission row -> a retried confirm hits the unique file_key index and gets the existing row back
    // Without it a double-tap becomes multiple pending rows, and duplicate catalog copies on approval
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

/** Extract and VERIFY the Bearer access token -> null means unauthenticated -> never decode without verifying. */
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
