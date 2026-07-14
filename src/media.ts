/**
 * Admin media presign — POST /{app}/media/upload-url.
 *
 * Presigns a PUT to a CANONICAL catalog key prefix (per-app key scheme from the
 * registry) so operator uploads land where that app's build-catalog expects
 * them. The server owns the id + key naming; the browser can't choose an
 * arbitrary key. Bytes go browser→R2 directly (zero-egress).
 */

import type { Context } from "hono";
import type { Env } from "./env.js";
import type { AppDef } from "./registry.js";
import { presignPut } from "./lib/r2.js";
import { categorySlug } from "./lib/util.js";
import {
  MAX_BYTES_BY_MIME as ALLOWED,
  EXT_BY_MIME as EXT,
} from "./lib/media-constraints.js";

function err(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

export function makeUploadUrlHandler(app: AppDef) {
  return async (c: Context<{ Bindings: Env }>): Promise<Response> => {
    let body: {
      kind?: string;
      slot?: string;
      contentType?: string;
      size?: number;
      category?: string;
    };
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

    let category: string | null = null;
    if (app.hasCategories) {
      category = categorySlug(body.category);
      if (!category) return err(400, "missing_field", "category is required");
    }

    const max = ALLOWED[contentType];
    if (max === undefined) return err(400, "bad_type", `File type not allowed: ${contentType}`);
    if (typeof size === "number" && size > max) {
      return err(
        400,
        "too_large",
        `File too large. Max ${Math.round(max / (1024 * 1024))}MB for ${contentType}`,
      );
    }

    const prefix = app.keyPrefixFor(kind, contentType, category);
    if (!prefix) return err(400, "bad_target", "Unsupported kind / slot / contentType combination");

    const ext = EXT[contentType];
    if (!ext) return err(400, "bad_type", `No extension mapping for ${contentType}`);

    const id = crypto.randomUUID();
    const key = `${prefix}/${id}.${ext}`;

    try {
      const uploadUrl = await presignPut(c.env, app.bucketName, key, contentType, 600);
      return c.json({ id, key, uploadUrl });
    } catch (e) {
      console.error(`[cms/${app.slug}/media/upload-url] presign error:`, e);
      return err(500, "server_error", "Failed to generate upload URL");
    }
  };
}
