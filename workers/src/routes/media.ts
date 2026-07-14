/**
 * Media routes (all gated — require valid access JWT):
 *
 *   POST /media/signed-url     — presigned R2 GET URL for private media (apply gate)
 *   POST /media/upload-url     — presigned R2 PUT URL for user submissions
 *   POST /media/confirm-upload — record a completed upload as a content_submission
 *
 * Key decisions (from architecture.md §3.2):
 *   - Wallpaper full_key is PUBLIC in the catalog (free
 *     preview/stream via CDN). /media/signed-url is only called at apply/set/save
 *     time (write to device).
 *   - ALL content requires premium to apply/set/save (product decision
 *     2026-07-01 — every wallpaper is premium). entitlement.isPremium()
 *     is checked live from Neon on every request here — never from the token. This
 *     is a SOFT gate: the public CDN keys mean a determined user could still fetch
 *     raw URLs; acceptable for v1. (The per-row is_premium flag was removed 2026-07-01.)
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken } from "../lib/jwt.js";
import { isPremium } from "../lib/entitlement.js";
import { presignGet, presignPut } from "../lib/r2.js";
import { getDb } from "../lib/db.js";
import { MAX_BYTES_BY_MIME as ALLOWED } from "../lib/media-constraints.js";

// Maps kind → { table, privateKeyCol }
// Wallpaper full_key is intentionally included (it's the apply gate key).
const KIND_TABLE: Record<string, { table: string; keyCol: string }> = {
  wallpaper: { table: "wallpapers", keyCol: "full_key" },
};

// ── POST /media/signed-url ───────────────────────────────────────────────────

export async function handleSignedUrl(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: { id?: string; kind?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { id, kind } = body;
  if (!id || typeof id !== "string" || !id.trim()) {
    return errorResponse(400, "missing_field", "id is required");
  }
  if (!kind || !KIND_TABLE[kind]) {
    return errorResponse(
      400,
      "invalid_kind",
      "kind must be one of: wallpaper",
    );
  }

  const { table, keyCol } = KIND_TABLE[kind];
  const sql = getDb(env);

  try {
    // Look up content row — fetch the private key only. (is_premium was removed
    // 2026-07-01; gating no longer depends on a per-row flag — see below.)
    const rows = await sql`
      SELECT ${sql(keyCol)} AS private_key
      FROM ${sql(table)}
      WHERE id = ${id}
        AND is_published = true
      LIMIT 1
    `;

    if (rows.length === 0) {
      return errorResponse(404, "not_found", "Content not found");
    }

    const row = rows[0];
    const privateKey = row.private_key as string | null;
    if (!privateKey) {
      return errorResponse(404, "not_found", "Content key not available");
    }

    // Entitlement check — ALL content is premium (product decision 2026-07-01:
    // every wallpaper apply/set/save requires a subscription). There is
    // no per-row flag anymore (is_premium was removed) and no test allow-list
    // bypass (PREMIUM_TEST_USER_IDS was removed); premium is read live from Neon,
    // so a declined/failed payment can never unlock content. Browse/preview stay
    // free — they use the public CDN keys directly and never reach this route.
    const premium = await isPremium(sql, sub);
    if (!premium) {
      return errorResponse(403, "premium_required", "Premium subscription required");
    }

    const url = await presignGet(env, privateKey, 300);
    return c.json({ url, expiresIn: 300 });
  } catch (err) {
    console.error("[media/signed-url] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
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
  if (kind !== "wallpaper") {
    return errorResponse(400, "invalid_kind", "kind must be one of: wallpaper");
  }
  if (!fileKey || typeof fileKey !== "string") {
    return errorResponse(400, "missing_field", "fileKey is required");
  }
  // Enforce key still belongs to this user
  if (!fileKey.startsWith(`user/${sub}/`)) {
    return errorResponse(400, "bad_key", "fileKey must be under your user/ prefix");
  }

  // The upload must have actually landed — otherwise the row is a dead entry the
  // moderation queue can never preview or approve.
  try {
    const head = await env.R2.head(fileKey);
    if (!head) {
      return errorResponse(400, "not_uploaded", "Upload not found — complete the upload first");
    }
  } catch (err) {
    console.error("[media/confirm-upload] R2 head error:", err);
    return errorResponse(500, "server_error", "Could not verify the upload");
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
