/**
 * Catalog builder — generates the edge-cached catalog JSON from Neon.
 *
 * Logic:
 *   - Queries Neon for published rows (via Hyperdrive)
 *   - Validates: wallpapers need full_key; live wallpapers need video/mp4 mime
 *   - Strips private keys per scope:
 *       wallpapers → keep full_key (public preview) + category (the browse axis)
 *   - Paginates 20/page (PAGE_SIZE=20) with the exact catalog JSON shape
 *   - Writes per-scope all_N.json to R2 (App filters by category client-side)
 *
 * Additional outputs (written on every build):
 *   - catalog/app_config.json            — PUBLIC app_config subset (no secrets)
 *
 * Catalog JSON shape (unchanged — app compatibility):
 *   { page, per_page, total, total_pages, has_more, items }
 *
 * Cron safety net (architecture.md §4):
 *   Compares the app_config.content_version (bigint) COLUMN against the
 *   last-built version in KV. If versions match, skips rebuild for that scope.
 *   This avoids needless R2 writes every hour when nothing changed.
 *   (Previously this incorrectly read feature_flags.content_version — fixed.)
 *
 * R2 writes:
 *   Uses the R2 Workers API binding (not S3 presign) for writes, which is
 *   more efficient in this context (no outbound HTTP, no signing overhead).
 *   The bucket must have public access enabled in the Cloudflare dashboard.
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { putPublicJson, getJsonString } from "../lib/r2.js";

const PAGE_SIZE = 20;

// ── Types ─────────────────────────────────────────────────────────────────────

type ContentRow = Record<string, unknown>;

interface ScopeResult {
  pages: number;
  items: number;
  skipped: number;
  /** Orphaned page files removed this build (stale tags / shrunk page counts). */
  deleted: number;
}

interface BuildResults {
  [scope: string]: ScopeResult | { error: string } | { skipped: "no_change" };
}

// ── R2 binding name in wrangler.toml ─────────────────────────────────────────
// We need the R2 binding (R2Bucket) for writes, not the S3 presign API.
// The binding is declared in wrangler.toml as [[r2_buckets]] binding = "R2".
// Add this to wrangler.toml and Env interface when the R2 binding is created.
// For now we fall back to putPublicJson which accepts an R2Bucket.

/**
 * Build catalog pages for one or all scopes.
 * @param env   Worker environment
 * @param scope Optional scope filter; null = all enabled scopes
 */
export async function buildCatalog(
  env: Env,
  scope: string | null,
  force = false,
): Promise<BuildResults> {
  const allScopes = ["wallpapers"];
  const scopes = scope ? [scope] : allScopes;

  const sql = getDb(env);
  const results: BuildResults = {};

  // ── Change-detection signal ────────────────────────────────────────────────
  // BUG FIX: read the dedicated app_config.content_version (bigint) column,
  // NOT feature_flags. Per architecture.md §4 and db/schema.sql, the operator
  // or content editor bumps content_version on any content change; the cron
  // compares it against the last-built version stored in KV and skips unchanged scopes.
  // content_version is a bigint, so postgres.js may return it as a string —
  // normalize to a canonical string for comparison (avoids precision loss).
  let contentVersion: string | null = null;
  let appConfigRow: Record<string, unknown> | null = null;
  try {
    const cfgRows = await sql`
      SELECT content_version, prices, support_email,
             policy_urls, feature_flags, min_supported_version
      FROM app_config WHERE id = 1 LIMIT 1
    `;
    if (cfgRows.length > 0) {
      appConfigRow = cfgRows[0] as Record<string, unknown>;
      const cv = appConfigRow["content_version"];
      contentVersion = cv === null || cv === undefined ? null : String(cv);
    }
  } catch (err) {
    console.warn("[build-catalog] Could not fetch app_config:", err);
  }

  // ── Always write the PUBLIC app_config.json subset ─────────────────────────
  // This is cheap (one R2 write) and the app reads it on launch via the CDN.
  // NEVER include secrets — only the public subset that AppConfigModel expects.
  if (appConfigRow) {
    try {
      await writeAppConfig(env.R2 as R2Bucket, appConfigRow);
    } catch (err) {
      console.error("[build-catalog] Failed to write app_config.json:", err);
    }
  }

  for (const s of scopes) {
    try {
      // Change-detection: compare content_version against last-built version in
      // KV. Skipped when force=true (operator-triggered builds always rebuild —
      // the gate is purely a cron optimization, and applying it to explicit
      // builds could skip a rebuild a publish/delete actually needs, leaving the
      // catalog stale).
      if (!force && contentVersion !== null) {
        const kvKey = `catalog_version:${s}`;
        const lastBuilt = await env.KV.get(kvKey);
        if (lastBuilt === contentVersion) {
          results[s] = { skipped: "no_change" };
          continue;
        }
      }

      const result = await buildScope(sql, env.R2 as R2Bucket, s);
      results[s] = result;

      // Update last-built version in KV
      if (contentVersion !== null) {
        await env.KV.put(`catalog_version:${s}`, contentVersion);
      }
    } catch (err) {
      console.error(`[build-catalog] failed for scope=${s}:`, err);
      results[s] = { error: String(err) };
    }
  }

  // ── Write the always-fresh version pointer LAST (commit marker) ─────────────
  // The app reads catalog/version.json (served no-store) to learn the current
  // content_version, then appends ?v=<version> to every catalog fetch. Writing it
  // only AFTER every page body is durably in R2 — and only if no scope errored —
  // means advertising version N guarantees N's content already exists, so an app
  // that polls the pointer can never request a ?v=N page that isn't built yet.
  // See docs/architecture.md §4.2 + admin/publish.ts (purge backstop).
  const anyScopeError = Object.values(results).some(
    (r) => r && typeof r === "object" && "error" in r,
  );
  if (contentVersion !== null && !anyScopeError) {
    try {
      await writeVersionPointer(env.R2 as R2Bucket, contentVersion);
    } catch (err) {
      console.error("[build-catalog] Failed to write version.json:", err);
    }
  }

  await sql.end();
  return results;
}

// ── Always-fresh version pointer ────────────────────────────────────────────

/**
 * Write catalog/version.json with the current content_version, served no-store so
 * it always reflects the latest publish. This is the only file the app must fetch
 * fresh; everything else is keyed by ?v=<version> and stays edge-cacheable.
 */
export async function writeVersionPointer(
  r2Bucket: R2Bucket,
  contentVersion: string,
): Promise<void> {
  await putPublicJson(
    r2Bucket,
    "catalog/version.json",
    { content_version: contentVersion, built_at: new Date().toISOString() },
    "no-store",
  );
}

// ── Public app_config.json ────────────────────────────────────────────────────

/**
 * Coerce a jsonb column to a real object. postgres.js with fetch_types:false
 * (required for Hyperdrive) returns jsonb as the raw JSON *string*, so passing it
 * straight through would double-encode it in the catalog (prices: "{...}" instead
 * of prices: {...}), which AppConfigModel.fromJson then fails to parse. Parse the
 * string here; pass real objects through unchanged.
 */
function asJsonObject(v: unknown): unknown {
  if (typeof v === "string") {
    try {
      return JSON.parse(v);
    } catch {
      return {};
    }
  }
  return v ?? {};
}

/**
 * Write the PUBLIC subset of app_config to catalog/app_config.json.
 * Matches AppConfigModel.fromJson (snake_case): prices, support_email,
 * policy_urls, feature_flags, min_supported_version.
 * NEVER includes content_version or any secret.
 */
export async function writeAppConfig(
  r2Bucket: R2Bucket,
  cfg: Record<string, unknown>,
): Promise<void> {
  const publicConfig = {
    prices: asJsonObject(cfg["prices"]),
    support_email: (cfg["support_email"] as string | null) ?? null,
    policy_urls: asJsonObject(cfg["policy_urls"]),
    feature_flags: asJsonObject(cfg["feature_flags"]),
    min_supported_version: (cfg["min_supported_version"] as string | null) ?? null,
  };
  await putPublicJson(r2Bucket, "catalog/app_config.json", publicConfig);
}

// ── Postgres text[] normalization ──────────────────────────────────────────────
// postgres.js with fetch_types:false (required for Hyperdrive) cannot detect array
// column types, so it returns text[] as the raw Postgres literal string ("{}",
// "{Azaan}", '{"a b",c}'). Convert to a real JS array; already-array values pass through.
function pgTextArrayToList(v: unknown): string[] {
  if (Array.isArray(v)) return v as string[];
  if (typeof v !== "string") return [];
  const s = v.trim();
  if (s === "" || s === "{}") return [];
  if (!s.startsWith("{") || !s.endsWith("}")) return [s];
  const inner = s.slice(1, -1);
  const out: string[] = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === '"') {
      if (inQuotes && inner[i + 1] === '"') {
        cur += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch === "\\" && inQuotes) {
      cur += inner[i + 1] ?? "";
      i++;
    } else if (ch === "," && !inQuotes) {
      out.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out.map((x) => x.trim()).filter((x) => x.length > 0);
}

// ── Per-scope builder ─────────────────────────────────────────────────────────

async function buildScope(
  sql: ReturnType<typeof getDb>,
  r2Bucket: R2Bucket,
  scope: string,
): Promise<ScopeResult> {

  // Fetch all published rows — order by sort_order for wallpapers, id for others
  let rows: ContentRow[];
  if (scope === "wallpapers") {
    // sort_order is no longer surfaced in the CMS (defaults to 0), so created_at
    // is the real tiebreaker — newest first within an equal sort_order.
    rows = await sql`
      SELECT * FROM wallpapers
      WHERE is_published = true
      ORDER BY sort_order ASC, created_at DESC
    `;
  } else {
    throw new Error(`[build-catalog] unknown scope: ${scope}`);
  }

  // ── Validate rows ──────────────────────────────────────────────────────────
  let skipped = 0;
  const validRows = rows.filter((row) => {
    if (scope === "wallpapers") {
      if (!row["full_key"]) {
        console.warn(`[build-catalog] skipping wallpaper id=${row["id"]}: missing full_key`);
        skipped++;
        return false;
      }
      if (row["type"] === "live" && row["mime"] !== "video/mp4") {
        console.warn(
          `[build-catalog] skipping live wallpaper id=${row["id"]}: invalid mime=${row["mime"]}`,
        );
        skipped++;
        return false;
      }
      return true;
    }
    // Wallpapers is the only scope in Arul.
    console.warn(`[build-catalog] skipping unknown-scope row id=${row["id"]}`);
    skipped++;
    return false;
  });

  // ── Strip private keys + columns the app never reads ───────────────────────
  // We keep ONLY what the Flutter models consume so catalog pages stay lean.
  // Required model fields (id, title, type, tags, full_key,
  // is_published, sort_order) are always retained. The dropped columns are
  // always-null or unread in v1; re-add to the keep-set if a model starts using one.
  //   wallpapers: drop mime, duration_ms, width, height, bytes
  //               (created_at STAYS — the app's "New" tab windows the feed to the
  //               last 7 days client-side; postgres.js emits it as an ISO-8601
  //               "…Z" string that Dart's DateTime.parse consumes directly.)
  //   `category` (the browse axis — feed chips filter on it) is always emitted.
  const publicRows = validRows.map((row) => {
    const r = { ...row } as Record<string, unknown>;
    // Normalize text[] columns: postgres.js (fetch_types:false, required for
    // Hyperdrive) returns array columns as the raw literal string e.g. "{Azaan}".
    // The Flutter models cast `tags` to List<dynamic>, so emit a real JSON array.
    if ("tags" in r) r["tags"] = pgTextArrayToList(r["tags"]);

    // wallpapers — the only scope in Arul. `category` (the browse axis) is
    // emitted as-is; it must never be dropped here.
    for (const k of ["audio_key", "mime", "duration_ms", "width", "height", "bytes"]) {
      delete r[k];
    }
    return r;
  });

  // ── Write paginated "all" catalog ──────────────────────────────────────────
  // Track every key this build writes so we can delete pages this build no longer
  // produces (empty tags, shrunk page counts). build-catalog is otherwise write-
  // only: without this cleanup, deleting the last row of a tag leaves the old tag
  // page (e.g. a legacy tag_1.json) orphaned in R2, still serving the deleted item forever.
  const writtenKeys = new Set<string>();

  const totalPages = Math.max(1, Math.ceil(publicRows.length / PAGE_SIZE));
  for (let page = 1; page <= totalPages; page++) {
    const pageItems = publicRows.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
    const key = `catalog/${scope}/all_${page}.json`;
    await putPublicJson(r2Bucket, key, {
      page,
      per_page: PAGE_SIZE,
      total: publicRows.length,
      total_pages: totalPages,
      has_more: page < totalPages,
      items: pageItems,
    });
    writtenKeys.add(key);
  }

  // The app filters by CATEGORY client-side over the shared all_*.json pages
  // (see the feed notifiers) — still ONE all_{page} page set, no per-category
  // files. No per-tag pages are written; any legacy tag pages are swept by
  // deleteOrphanedPages below.

  // ── Delete orphaned pages this build did not (re)write ─────────────────────
  // Everything under catalog/<scope>/ that isn't a page we just wrote is stale
  // (a removed tag, or a higher page number from when the scope was larger).
  const deleted = await deleteOrphanedPages(r2Bucket, scope, writtenKeys);

  return { pages: totalPages, items: publicRows.length, skipped, deleted };
}

/**
 * Delete catalog/<scope>/*.json objects that the current build did NOT write.
 * Only touches the scope's own page files (all_N.json, <slug>_N.json); never the
 * shared top-level files (version.json, app_config.json), which live at
 * catalog/ not catalog/<scope>/. Returns the count deleted.
 */
export async function deleteOrphanedPages(
  r2Bucket: R2Bucket,
  scope: string,
  writtenKeys: Set<string>,
): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const opts: R2ListOptions = { prefix: `catalog/${scope}/`, limit: 1000 };
    if (cursor) opts.cursor = cursor;
    const listed = await r2Bucket.list(opts);
    for (const obj of listed.objects) {
      // Only manage the JSON page files; ignore anything else that may share the prefix.
      if (!obj.key.endsWith(".json")) continue;
      if (writtenKeys.has(obj.key)) continue;
      try {
        await r2Bucket.delete(obj.key);
        deleted++;
      } catch (err) {
        console.error(`[build-catalog] failed to delete orphan ${obj.key}:`, err);
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return deleted;
}

// Re-export getJsonString for version-check helper usage by tests
export { getJsonString };
