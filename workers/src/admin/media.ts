/**
 * Admin media presign — POST /admin/media/upload-url.
 *
 * Unlike the user-facing /media/upload-url (which locks keys to user/<sub>/),
 * this presigns a PUT to a CANONICAL catalog key prefix so operator uploads land
 * where build-catalog expects them. The server owns the id + key naming (the
 * canonical build-catalog layout), so the browser can't choose an arbitrary key.
 * Bytes go browser→R2 directly (zero-egress); they never transit the Worker.
 *
 * Prefixes (canonical R2 key layout build-catalog expects):
 *   wallpaper (static or live) → wallpapers/<category>/{id}.{jpg|png|webp|mp4}
 *   (Arul keys are CATEGORY-partitioned — the browse axis — not the reference's
 *   posters/full split. Categories are free text; see CLAUDE.md §5b.)
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { presignPut } from "../lib/r2.js";
import {
  MAX_BYTES_BY_MIME as ALLOWED,
  EXT_BY_MIME as EXT,
} from "../lib/media-constraints.js";

/**
 * Normalize a free-text category into the R2 key segment. Lowercased; spaces
 * collapse to "-"; only [a-z0-9_-] survive. Returns null when nothing usable
 * remains (a category is REQUIRED — it is the key partition and the browse axis).
 */
export function categorySlug(category: unknown): string | null {
  if (typeof category !== "string") return null;
  const slug = category
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]/g, "");
  return slug.length > 0 && slug.length <= 64 ? slug : null;
}

// slot (sent by the uploader for legacy multi-object kinds) is no longer needed:
// the prefix derives from kind + contentType + category.
export function prefixFor(kind: string, contentType: string, category: string): string | null {
  if (kind === "wallpaper") {
    if (contentType.startsWith("image/") || contentType === "video/mp4") {
      return `wallpapers/${category}`;
    }
    return null;
  }
  return null;
}

function err(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

export async function handleAdminUploadUrl(c: Context<{ Bindings: Env }>): Promise<Response> {
  let body: { kind?: string; slot?: string; contentType?: string; size?: number; category?: string };
  try {
    body = await c.req.json();
  } catch {
    return err(400, "invalid_body", "Request body must be valid JSON");
  }

  const { kind, contentType, size } = body;
  if (!kind || typeof kind !== "string") return err(400, "missing_field", "kind is required");
  if (!contentType || typeof contentType !== "string") {
    return err(400, "missing_field", "contentType is required");
  }
  const category = categorySlug(body.category);
  if (!category) return err(400, "missing_field", "category is required");

  const max = ALLOWED[contentType];
  if (max === undefined) return err(400, "bad_type", `File type not allowed: ${contentType}`);
  if (typeof size === "number" && size > max) {
    return err(400, "too_large", `File too large. Max ${Math.round(max / (1024 * 1024))}MB for ${contentType}`);
  }

  const prefix = prefixFor(kind, contentType, category);
  if (!prefix) return err(400, "bad_target", "Unsupported kind / slot / contentType combination");

  const ext = EXT[contentType];
  if (!ext) return err(400, "bad_type", `No extension mapping for ${contentType}`);

  const id = crypto.randomUUID();
  const key = `${prefix}/${id}.${ext}`;

  try {
    const uploadUrl = await presignPut(c.env, key, contentType, 600);
    return c.json({ id, key, uploadUrl });
  } catch (e) {
    console.error("[admin/media/upload-url] presign error:", e);
    return err(500, "server_error", "Failed to generate upload URL");
  }
}
