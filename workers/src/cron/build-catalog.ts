/**
 * The page shape `{ page, per_page, total, total_pages, has_more, items }` is an APP contract -> never change it
 * That column, NOT feature_flags.content_version -> reading the wrong one silently froze the catalog
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { putPublicJson, getJsonString } from "../lib/r2.js";
import { rankFor } from "../lib/feed-score.js";

// 200/page holds ringtones to one page and the wallpaper library to a handful -> one parallel batch after page 1
// The app reads per_page/total_pages out of the JSON -> this size is not a client contract -> it can change freely
const PAGE_SIZE = 200;

const CATALOG_PAGE_CACHE_CONTROL = "public, max-age=86400";

type ContentRow = Record<string, unknown>;

interface ScopeResult {
  pages: number;
  items: number;
  skipped: number;
  deleted: number;
}

interface BuildResults {
  [scope: string]: ScopeResult | { error: string } | { skipped: "no_change" } | { skipped: "locked" };
}

export async function buildCatalog(env: Env, scope: string | null, force = false): Promise<BuildResults> {
  // deleteOrphanedPages removes every page THIS build did not write -> it eats a concurrent build's higher pages
  // total_pages then advertises pages that 404 -> the feed truncates for everyone mid-scroll
  // writeVersionPointer is last-writer-wins -> an OLDER build finishing second rewinds version.json
  // KV is eventually consistent -> this is a best-effort lock, not a mutex -> it collapses the same-minute overlap
  // The monotonic guard in writeVersionPointer covers whatever slips through -> both defences are needed
  const lockHolder = crypto.randomUUID();
  const lockHeld = await acquireBuildLock(env, lockHolder);
  if (!lockHeld) {
    console.log("[build-catalog] Another build holds the lock — skipping this run");
    return { _lock: { skipped: "locked" } };
  }
  try {
    return await buildCatalogLocked(env, scope, force);
  } finally {
    await releaseBuildLock(env, lockHolder);
  }
}

/** KV key + TTL for the build lock -> a crashed build never releases -> the TTL is what bounds its stale lock. */
const BUILD_LOCK_KEY = "catalog_build_lock";
const BUILD_LOCK_TTL_SECONDS = 300; // 5 min — far longer than a real build

async function acquireBuildLock(env: Env, holder: string): Promise<boolean> {
  try {
    const current = await env.KV.get(BUILD_LOCK_KEY);
    if (current !== null) return false;
    await env.KV.put(BUILD_LOCK_KEY, holder, {
      expirationTtl: BUILD_LOCK_TTL_SECONDS,
    });
    return true;
  } catch (err) {
    // KV being unavailable must not block publishing -> proceed unlocked rather than freeze the catalog
    console.warn("[build-catalog] lock acquire failed, proceeding unlocked:", err);
    return true;
  }
}

async function releaseBuildLock(env: Env, holder: string): Promise<void> {
  try {
    // Clear only OUR lock -> deleting one a later build took after ours expired hands it two concurrent writers
    const current = await env.KV.get(BUILD_LOCK_KEY);
    if (current === holder) await env.KV.delete(BUILD_LOCK_KEY);
  } catch (err) {
    console.warn("[build-catalog] lock release failed (TTL will clear it):", err);
  }
}

async function buildCatalogLocked(env: Env, scope: string | null, force: boolean): Promise<BuildResults> {
  const allScopes = ["wallpapers", "ringtones", "statuses"];
  const scopes = scope ? [scope] : allScopes;

  const sql = getDb(env);
  const results: BuildResults = {};

  try {
    // It is a bigint -> postgres.js may hand it back as a string -> normalize before comparing, never lose precision
    let contentVersion: string | null = null;
    let appConfigRow: Record<string, unknown> | null = null;
    let cfgErr: unknown = null;

    for (let attempt = 0; attempt < 2; attempt++) {
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
        cfgErr = null;
        break;
      } catch (err) {
        cfgErr = err;
        if (attempt === 0) {
          console.warn("[build-catalog] app_config read failed — retrying once on a fresh connection:", err);
        }
      }
    }

    // A null contentVersion DISABLES the change-detection gate below -> falling through runs a FULL buildScope
    // That is the most expensive thing here, against the connection that just failed, and it skips version.json anyway
    // Bail cheaply and mark every requested scope errored -> the caller's anyScopeError guard then skips the sweep
    if (cfgErr !== null) {
      console.error(
        "[build-catalog] Could not fetch app_config after retry — skipping rebuild this run:",
        cfgErr,
      );
      for (const s of scopes) {
        results[s] = { error: `app_config unreadable: ${String(cfgErr)}` };
      }
      return results;
    }

    if (appConfigRow) {
      try {
        await writeAppConfig(env.R2 as R2Bucket, appConfigRow, await readCategoryOrder(sql));
      } catch (err) {
        console.error("[build-catalog] Failed to write app_config.json:", err);
      }
    }

    for (const s of scopes) {
      try {
        // The gate is purely a cron optimization -> force=true always rebuilds -> an operator asked for this one
        // Applying it to an explicit build could skip a rebuild a publish or delete actually needed
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

        if (contentVersion !== null) {
          await env.KV.put(`catalog_version:${s}`, contentVersion);
        }
      } catch (err) {
        console.error(`[build-catalog] failed for scope=${s}:`, err);
        results[s] = { error: String(err) };
      }
    }

    // Written only AFTER every page body is durably in R2, and only when no scope errored -> this is the COMMIT
    // So advertising version N guarantees N's pages exist -> a polling app can never request a ?v=N that is unbuilt
    const anyScopeError = Object.values(results).some((r) => r && typeof r === "object" && "error" in r);
    if (contentVersion !== null && !anyScopeError) {
      try {
        await writeVersionPointer(env.R2 as R2Bucket, contentVersion);
      } catch (err) {
        console.error("[build-catalog] Failed to write version.json:", err);
      }
    }

    return results;
  } finally {
    await sql.end().catch(() => {});
  }
}

const VERSION_POINTER_CACHE_CONTROL = "public, max-age=30, stale-while-revalidate=300";

/** The ONLY file the app must fetch near-fresh -> everything else is keyed by ?v= and stays fully edge-cacheable. */
export async function writeVersionPointer(r2Bucket: R2Bucket, contentVersion: string): Promise<void> {
  // MONOTONIC -> never advertise a version older than the one already published
  // Writing it anyway rewinds every client's ?v= and hides freshly published content until the next bump
  // Only a STRICTLY older version is refused -> re-writing the SAME one is allowed on purpose
  // Cache-Control is stored object METADATA -> a policy fix would otherwise wait for someone to publish content
  const current = await readVersionPointer(r2Bucket);
  if (current !== null && isNewerVersion(current, contentVersion)) {
    console.log(`[build-catalog] version.json already at ${current}; not rewinding to ${contentVersion}`);
    return;
  }
  await putPublicJson(
    r2Bucket,
    "catalog/version.json",
    { content_version: contentVersion, built_at: new Date().toISOString() },
    VERSION_POINTER_CACHE_CONTROL,
  );
}

async function readVersionPointer(r2Bucket: R2Bucket): Promise<string | null> {
  try {
    const raw = await getJsonString(r2Bucket, "catalog/version.json");
    if (raw === null) return null;
    const parsed = JSON.parse(raw) as { content_version?: unknown };
    const v = parsed.content_version;
    return typeof v === "string" || typeof v === "number" ? String(v) : null;
  } catch {
    // An unreadable or corrupt pointer must not block a rebuild -> treat it as absent -> this build republishes it
    return null;
  }
}

/**
 * True when `candidate` is strictly newer than `current`.
 *
 * content_version is a bigint -> compare NUMERICALLY -> a string compare ranks "9" above "10" and wedges the pointer
 * Non-numeric input falls back to "treat as newer" -> a malformed existing pointer must always be overwritable
 */
export function isNewerVersion(candidate: string, current: string): boolean {
  const a = Number(candidate);
  const b = Number(current);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return true;
  return a > b;
}

/**
 * Coerce a jsonb column to a real object, for LEGACY ROWS ONLY.
 * Keep this until no such row is left, then delete it — a reader that silently repairs its input is
 * why nothing surfaced for months. AppConfigModel.fromJson cannot parse a double-encoded blob.
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

export type CategoryOrder = Record<string, string[]>;

/**
 * The hand-set chip order, read from the `categories` table the unified CMS writes.
 *
 * This is the ONE thing that table feeds into the catalog. Everything else about a
 * category still comes from the items themselves: a chip EXISTS because a published
 * row carries the slug, and that stays true -> this only decides the order they sit in.
 * So a category never appears because of this list, and never disappears without it.
 *
 * Only positioned rows (`picker_order > 0`) are emitted; the CMS numbers a whole kind
 * 1..N on save, so an untouched install emits nothing and the app keeps its built-in
 * order. A missing table is the same case -> the CMS may be deployed before the
 * migration, and the hourly cron must not start failing over it.
 */
export async function readCategoryOrder(sql: ReturnType<typeof getDb>): Promise<CategoryOrder> {
  try {
    const rows = (await sql`
      SELECT kind, slug FROM categories
      WHERE picker_order > 0
      ORDER BY kind, picker_order
    `) as unknown as { kind: string; slug: string }[];
    const out: CategoryOrder = {};
    for (const r of rows) {
      // CMS kinds are singular ('wallpaper'), catalog scopes plural ('wallpapers').
      // A status slug must never land in the wallpaper chip order -> fielded builds read only that key
      const scope = r.kind === "ringtone" ? "ringtones" : r.kind === "status" ? "statuses" : "wallpapers";
      // biome-ignore lint/suspicious/noAssignInExpressions: create-or-append idiom
      (out[scope] ??= []).push(r.slug);
    }
    return out;
  } catch (err) {
    // 42P01 = relation does not exist: expected before the migration lands.
    if ((err as { code?: string } | null)?.code !== "42P01") {
      console.error("[build-catalog] category order unreadable:", err);
    }
    return {};
  }
}

/**
 * The PUBLIC subset of app_config -> snake_case, matching AppConfigModel.fromJson exactly.
 * NEVER emit content_version or any secret here -> this object is world-readable on the CDN
 */
export async function writeAppConfig(
  r2Bucket: R2Bucket,
  cfg: Record<string, unknown>,
  categoryOrder: CategoryOrder = {},
): Promise<void> {
  const publicConfig = {
    prices: asJsonObject(cfg["prices"]),
    support_email: (cfg["support_email"] as string | null) ?? null,
    policy_urls: asJsonObject(cfg["policy_urls"]),
    feature_flags: asJsonObject(cfg["feature_flags"]),
    min_supported_version: (cfg["min_supported_version"] as string | null) ?? null,
    category_order: categoryOrder,
  };
  await putPublicJson(r2Bucket, "catalog/app_config.json", publicConfig);
}

// `fetch_types:false` cannot detect array column types -> text[] arrives as the raw literal string, e.g. "{Azaan}"
// The Flutter models cast those fields to List -> convert here; an already-array value passes through untouched
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

/** The total use count as of the last popularity bump -> the guard that makes a quiet day a no-op. */
const POPULARITY_TOTAL_KEY = "popularity_total";

/**
 * Counters are increment-only -> the total only grows -> any difference is real
 * An unreadable KV falls through to bumping -> a needless rebuild is the safe direction, a stale order is not
 */
export async function refreshPopularityOrder(
  env: Env,
): Promise<{ bumped: false; reason: string } | { bumped: true; total: number }> {
  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT
        (SELECT COALESCE(SUM(apply_count), 0) FROM wallpapers) +
        (SELECT COALESCE(SUM(set_count),   0) FROM ringtones)  AS total
    `;
    const total = pgBigintToNumber(rows[0]?.["total"]) + (await statusUseTotal(sql));

    let last: string | null = null;
    try {
      last = await env.KV.get(POPULARITY_TOTAL_KEY);
    } catch (err) {
      console.warn("[popularity] KV read failed — bumping anyway:", err);
    }
    if (last !== null && Number(last) === total) {
      return { bumped: false, reason: `no new uses (total ${total})` };
    }

    // The same column and the same +1 a CMS content write uses -> the change gate and every client's ?v= move together
    await sql`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
    await env.KV.put(POPULARITY_TOTAL_KEY, String(total));
    return { bumped: true, total };
  } finally {
    await sql.end().catch(() => {});
  }
}

/** Its own statement -> a missing statuses table (42P01) must not stop the wallpaper and ringtone bump. */
async function statusUseTotal(sql: ReturnType<typeof getDb>): Promise<number> {
  try {
    const rows = await sql`SELECT COALESCE(SUM(share_count + download_count), 0) AS total FROM statuses`;
    return pgBigintToNumber(rows[0]?.["total"]);
  } catch (err) {
    if ((err as { code?: string } | null)?.code === "42P01") return 0;
    throw err;
  }
}

/**
 * `fetch_types:false` hands bigint back as a STRING -> unconverted it ships as `"apply_count": "5"`
 * The Dart models cast that field to int -> EVERY catalog page then fails to parse -> the feed sticks on disk cache
 * Number() is exact here -> these are use counters, nowhere near 2^53
 */
function pgBigintToNumber(v: unknown): number {
  if (typeof v === "number") return Number.isFinite(v) ? v : 0;
  if (typeof v === "string") {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }
  if (typeof v === "bigint") return Number(v);
  return 0;
}

export async function buildScope(
  sql: ReturnType<typeof getDb>,
  r2Bucket: R2Bucket,
  scope: string,
): Promise<ScopeResult> {
  let rows: ContentRow[];
  if (scope === "wallpapers") {
    rows = await sql`
      SELECT * FROM wallpapers
      WHERE is_published = true
      ORDER BY feed_rank ASC NULLS LAST, apply_count DESC, created_at DESC, id ASC
    `;
  } else if (scope === "ringtones") {
    // The same contract on this table's own counter. `created_at` is only DEFAULTED, never NOT NULL here
    // So NULLS LAST -> a null sorts FIRST under DESC by default -> it would lead the whole ringtone feed
    // That asymmetry is real: wallpapers.created_at is NOT NULL, so only this clause needs the guard
    rows = await sql`
      SELECT * FROM ringtones
      WHERE is_published = true
      ORDER BY feed_rank ASC NULLS LAST, set_count DESC, created_at DESC NULLS LAST, id ASC
    `;
  } else if (scope === "statuses") {
    rows = await selectStatuses(sql);
  } else {
    throw new Error(`[build-catalog] unknown scope: ${scope}`);
  }

  let skipped = 0;
  const validRows = rows.filter((row) => {
    if (scope === "wallpapers") {
      if (!row["full_key"]) {
        console.warn(`[build-catalog] skipping wallpaper id=${row["id"]}: missing full_key`);
        skipped++;
        return false;
      }
      if (row["type"] === "live" && row["mime"] !== "video/mp4") {
        console.warn(`[build-catalog] skipping live wallpaper id=${row["id"]}: invalid mime=${row["mime"]}`);
        skipped++;
        return false;
      }
      return true;
    }
    if (scope === "ringtones") {
      if (!row["audio_key"]) {
        console.warn(`[build-catalog] skipping ringtone id=${row["id"]}: missing audio_key`);
        skipped++;
        return false;
      }
      return true;
    }
    if (scope === "statuses") {
      if (!row["full_key"] || row["mime"] !== "video/mp4") {
        console.warn(
          `[build-catalog] skipping status id=${row["id"]}: full_key=${row["full_key"]} mime=${row["mime"]}`,
        );
        skipped++;
        return false;
      }
      return true;
    }
    console.warn(`[build-catalog] skipping unknown-scope row id=${row["id"]}`);
    skipped++;
    return false;
  });

  // Already decided by the ORDER BY above -> validation only DROPS rows -> dropping preserves relative order
  // So the survivors are still in feed order and the ranks below stay contiguous, with no holes
  const orderedRows = validRows;

  // The whole catalog is drained before first paint -> every column is download weight -> keep the models' fields only
  // A dropped column is always-null or unread today -> re-add it to the keep-set the moment a model starts reading it
  // `renewed_at` STAYS on both as well -> tier 1 of New (a CMS Renew), windowed client-side exactly like published_at
  // It is not in either delete list below, so SELECT * carries it -> deleting it would silently flatten New's top tier
  // Ringtone `mime` STAYS -> set-as-ringtone infers the file extension from it
  // `apply_score`/`set_score`/`scored_at` are DROPPED -> retired decay state, read by nothing
  // Emitting them would invite the app to re-derive an order -> never put them back in the page
  const publicRows = orderedRows.map((row, i) => {
    const r = { ...row } as Record<string, unknown>;
    // `fetch_types:false` returns an array column as the raw literal string -> the Flutter models cast `tags` to a List
    if ("tags" in r) r["tags"] = pgTextArrayToList(r["tags"]);

    r["feed_rank"] = rankFor(i);
    delete r["scored_at"];
    // The CMS's Undo bookkeeping (db/schema/20_renew_undo.sql) -> never content, and no model reads it
    delete r["pre_renew_published_at"];

    if (scope === "wallpapers") {
      r["apply_count"] = pgBigintToNumber(r["apply_count"]);
      for (const k of ["audio_key", "mime", "duration_ms", "width", "height", "bytes", "apply_score"]) {
        delete r[k];
      }
      return r;
    }
    if (scope === "statuses") {
      // `width`/`height` STAY: a status keeps its source's shape, and the card is sized from them
      // before a byte of video lands (StatusVideo.aspect) -> dropping them would resize every card on first frame
      for (const k of ["mime", "bytes", "share_count", "download_count"]) {
        delete r[k];
      }
      return r;
    }
    // ringtones — the only other scope, and buildScope already threw on anything else
    r["set_count"] = pgBigintToNumber(r["set_count"]);
    for (const k of ["full_key", "duration_ms", "bytes", "set_score"]) {
      delete r[k];
    }
    return r;
  });

  // Track every key this build writes -> anything else under the scope is a page it no longer produces
  // build-catalog is otherwise write-only -> without this, a shrunk page count leaves an orphan serving deleted items
  const writtenKeys = new Set<string>();

  const totalPages = Math.max(1, Math.ceil(publicRows.length / PAGE_SIZE));
  for (let page = 1; page <= totalPages; page++) {
    const pageItems = publicRows.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
    const key = `catalog/${scope}/all_${page}.json`;
    await putPublicJson(
      r2Bucket,
      key,
      {
        page,
        per_page: PAGE_SIZE,
        total: publicRows.length,
        total_pages: totalPages,
        has_more: page < totalPages,
        items: pageItems,
      },
      CATALOG_PAGE_CACHE_CONTROL,
    );
    writtenKeys.add(key);
  }

  const deleted = await deleteOrphanedPages(r2Bucket, scope, writtenKeys);

  return { pages: totalPages, items: orderedRows.length, skipped, deleted };
}

/**
 * The Worker may deploy before 30_statuses.sql lands -> a missing table (42P01) is an empty scope, never an error
 * An error here would withhold version.json for EVERY scope -> fielded builds would stop seeing new wallpapers
 */
async function selectStatuses(sql: ReturnType<typeof getDb>): Promise<ContentRow[]> {
  try {
    return await sql`
      SELECT * FROM statuses
      WHERE is_published = true
      ORDER BY feed_rank ASC NULLS LAST, (share_count + download_count) DESC, created_at DESC, id ASC
    `;
  } catch (err) {
    if ((err as { code?: string } | null)?.code === "42P01") return [];
    throw err;
  }
}

/**
 * Scoped to catalog/<scope>/ -> version.json and app_config.json live at catalog/ -> they are never reachable here
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
      // Manage only the JSON page files -> anything else sharing this prefix is not ours to delete
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
