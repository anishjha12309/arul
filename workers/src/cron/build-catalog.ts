/**
 * Catalog builder — the edge-cached catalog JSON, generated from Neon. The browse feed never reads the DB.
 *
 * The page shape `{ page, per_page, total, total_pages, has_more, items }` is an APP contract -> never change it
 * Change detection compares the app_config.content_version COLUMN against KV -> an unchanged scope skips its rebuild
 * That column, NOT feature_flags.content_version -> reading the wrong one silently froze the catalog
 * Writes go through the R2 Workers BINDING, not an S3 presign -> no outbound HTTP, no signing overhead
 * The bucket's public access is a dashboard setting -> the binding cannot set an ACL -> it is not expressible here
 */

import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { putPublicJson, getJsonString } from "../lib/r2.js";
import { rankFor } from "../lib/feed-score.js";

// The app drains a WHOLE catalog before rendering -> category filtering is client-side -> every page is first-paint latency
// At 20/page that was ~5 s on device for both tabs, even through a 4-wide drain pool -> the page COUNT was the cost
// 200/page holds ringtones to one page and the wallpaper library to a handful -> one parallel batch after page 1
// The app reads per_page/total_pages out of the JSON -> this size is not a client contract -> it can change freely
const PAGE_SIZE = 200;

// Pages are fetched with `?v=<content_version>` -> a publish mints a new cache key -> a page body is immutable for its key
// max-age=60 made the edge revalidate against R2 origin on nearly every real fetch -> 0.5-1 s per page, worse outliers
// The only un-versioned fetch is the rare version.json-failed fallback -> a day bounds how stale that can get
const CATALOG_PAGE_CACHE_CONTROL = "public, max-age=86400";

// ── Types ─────────────────────────────────────────────────────────────────────

type ContentRow = Record<string, unknown>;

interface ScopeResult {
  pages: number;
  items: number;
  skipped: number;
  /** Orphaned page files removed this build — a stale tag page, or a page number a shrunk scope no longer reaches. */
  deleted: number;
}

interface BuildResults {
  [scope: string]:
    | ScopeResult
    | { error: string }
    | { skipped: "no_change" }
    | { skipped: "locked" };
}

/** Build catalog pages for one scope, or for all enabled scopes when `scope` is null. */
export async function buildCatalog(
  env: Env,
  scope: string | null,
  force = false,
): Promise<BuildResults> {
  // ── Mutual exclusion ───────────────────────────────────────────────────────
  // The CMS rebuilds on EVERY content mutation while the hourly cron rebuilds independently
  // So overlap is routine during a bulk publish -> and overlap is destructive here, two ways
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

async function buildCatalogLocked(
  env: Env,
  scope: string | null,
  force: boolean,
): Promise<BuildResults> {
  const allScopes = ["wallpapers", "ringtones"];
  const scopes = scope ? [scope] : allScopes;

  const sql = getDb(env);
  const results: BuildResults = {};

  try {
    // ── Change-detection signal ──────────────────────────────────────────────
    // The dedicated app_config.content_version COLUMN, NOT feature_flags -> a content write bumps it in that transaction
    // Compared against the last-built version in KV -> an unchanged scope skips its rebuild entirely
    // It is a bigint -> postgres.js may hand it back as a string -> normalize before comparing, never lose precision
    // RETRY ONCE: browse never touches the DB -> the Worker idles for hours -> this first query lands on a severed socket
    // That is a stale-pool artifact, not an outage -> a second attempt reconnects -> without it the whole hour is lost
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
          console.warn(
            "[build-catalog] app_config read failed — retrying once on a fresh connection:",
            err,
          );
        }
      }
    }

    // ── Abort if the DB is genuinely unreachable ─────────────────────────────
    // A null contentVersion DISABLES the change-detection gate below -> falling through runs a FULL buildScope
    // That is the most expensive thing here, against the connection that just failed, and it skips version.json anyway
    // The result was a 30 s stall the runtime killed -> it took the concurrently-scheduled autopay scan with it
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

    // ── Always write the PUBLIC app_config.json subset ───────────────────────
    // One R2 write, and the app reads it on every launch through the CDN -> cheap enough to do unconditionally
    // NEVER include a secret -> only the public subset AppConfigModel expects reaches this file
    if (appConfigRow) {
      try {
        await writeAppConfig(
          env.R2 as R2Bucket,
          appConfigRow,
          await readCategoryOrder(sql),
        );
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

    // ── Write the always-fresh version pointer LAST (commit marker) ───────────
    // The app reads catalog/version.json for the current content_version, then appends ?v= to every catalog fetch
    // Written only AFTER every page body is durably in R2, and only when no scope errored -> this is the COMMIT
    // So advertising version N guarantees N's pages exist -> a polling app can never request a ?v=N that is unbuilt
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

    return results;
  } finally {
    // Release on EVERY path, the early abort included -> the same try/finally autopay-notify.ts uses
    // Tearing down a socket Neon already dropped can itself REJECT -> and this is a `finally`
    // A rejection there REPLACES the return value -> a fully successful rebuild would surface as a failed promise
    // The caller would then skip the canonical sweep and log a failure that never happened -> swallow it
    await sql.end().catch(() => {});
  }
}

// ── Always-fresh version pointer ────────────────────────────────────────────

/**
 * Cache policy for the version pointer — the first request of every cold start, since every `?v=` comes from here.
 *
 * `no-store` made it the ONE uncacheable request on that path -> every launch, every user, went to origin at ~240 ms
 * `max-age=0, s-maxage=30` did NOT fix it -> Cloudflare answered DYNAMIC on every request and ignored the s-maxage
 * A non-zero `max-age` is what actually caches here -> `max-age=0` reads as "do not cache" and the edge never helps
 * Holding it client-side costs nothing -> the app uses `package:http`, which implements no HTTP cache
 * The price is a bounded staleness window -> a client may pin the previous `?v=` briefly and self-corrects on the next poll
 * That is safe because the pointer HINTS at freshness, never at correctness -> it is written last, after the pages
 * Keep `stale-while-revalidate` well above `s-maxage` -> it stops a burst of cold starts stampeding origin at expiry
 */
const VERSION_POINTER_CACHE_CONTROL =
  "public, max-age=30, stale-while-revalidate=300";

/** The ONLY file the app must fetch near-fresh -> everything else is keyed by ?v= and stays fully edge-cacheable. */
export async function writeVersionPointer(
  r2Bucket: R2Bucket,
  contentVersion: string,
): Promise<void> {
  // MONOTONIC -> never advertise a version older than the one already published
  // content_version only ever rises -> a lower value here means THIS build read an older snapshot than a finished one
  // Writing it anyway rewinds every client's ?v= and hides freshly published content until the next bump
  // Skipping is safe -> the newer pointer is already correct and this build's pages went to the same keys
  // Only a STRICTLY older version is refused -> re-writing the SAME one is allowed on purpose
  // Cache-Control is stored object METADATA -> a policy fix would otherwise wait for someone to publish content
  // The rewrite is idempotent where it matters -> content_version is unchanged, only built_at and the headers move
  const current = await readVersionPointer(r2Bucket);
  if (current !== null && isNewerVersion(current, contentVersion)) {
    console.log(
      `[build-catalog] version.json already at ${current}; not rewinding to ${contentVersion}`,
    );
    return;
  }
  await putPublicJson(
    r2Bucket,
    "catalog/version.json",
    { content_version: contentVersion, built_at: new Date().toISOString() },
    VERSION_POINTER_CACHE_CONTROL,
  );
}

/** Current published content_version, or null when absent/unreadable. */
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

// ── Public app_config.json ────────────────────────────────────────────────────

/**
 * Coerce a jsonb column to a real object.
 * `fetch_types:false` returns jsonb as the raw JSON STRING -> passing it through double-encodes it in the catalog
 * AppConfigModel.fromJson then fails to parse -> parse here, and pass real objects through unchanged
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

/** Chip order per scope, as the app consumes it: `{ wallpapers: [...], ringtones: [...] }`. */
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
export async function readCategoryOrder(
  sql: ReturnType<typeof getDb>,
): Promise<CategoryOrder> {
  try {
    const rows = (await sql`
      SELECT kind, slug FROM categories
      WHERE picker_order > 0
      ORDER BY kind, picker_order
    `) as unknown as { kind: string; slug: string }[];
    const out: CategoryOrder = {};
    for (const r of rows) {
      // CMS kinds are singular ('wallpaper'), catalog scopes plural ('wallpapers').
      const scope = r.kind === "ringtone" ? "ringtones" : "wallpapers";
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

// ── Postgres text[] normalization ──────────────────────────────────────────────
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

// ── Daily popularity refresh ──────────────────────────────────────────────────

/** The total use count as of the last popularity bump -> the guard that makes a quiet day a no-op. */
const POPULARITY_TOTAL_KEY = "popularity_total";

/**
 * Publish the day's accumulated apply/set counts to the feed.
 *
 * Applies land in Neon continuously, but the browse feed NEVER reads the DB -> a moved counter changes nothing
 * Only a new content_version mints a new `?v=` -> this bump IS the publish -> the next hourly build carries the order
 * It goes through the exact path a CMS publish uses -> nothing else has to know popularity exists
 * DAILY, never hourly -> popularity is a sort key, not news -> hourly would re-download the whole catalog 24x a day
 * Guarded on a KV-stored total -> a quiet day is a no-op, not a forced re-download for every install
 * Counters are increment-only -> the total only grows -> any difference is real
 * An unreadable KV falls through to bumping -> a needless rebuild is the safe direction, a stale order is not
 */
export async function refreshPopularityOrder(env: Env): Promise<
  { bumped: false; reason: string } | { bumped: true; total: number }
> {
  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT
        (SELECT COALESCE(SUM(apply_count), 0) FROM wallpapers) +
        (SELECT COALESCE(SUM(set_count),   0) FROM ringtones)  AS total
    `;
    const total = pgBigintToNumber(rows[0]?.["total"]);

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
    // See buildCatalogLocked -> end() can reject on a dropped connection -> in a finally that REPLACES the result
    await sql.end().catch(() => {});
  }
}

// ── Feed order ────────────────────────────────────────────────────────────────
// There is no ordering FUNCTION -> the order IS the ORDER BY in buildScope() below -> do not add one
// lib/feed-score.ts owns only the rank numbering -> read it for why the decayed score and round-robin are gone

// ── Postgres bigint normalization ─────────────────────────────────────────────
/**
 * Coerce a Postgres `bigint` column to a JS number — the same trap `content_version` above documents.
 *
 * `fetch_types:false` hands bigint back as a STRING -> unconverted it ships as `"apply_count": "5"`
 * The Dart models cast that field to int -> EVERY catalog page then fails to parse -> the feed sticks on disk cache
 * Number() is exact here -> these are use counters, nowhere near 2^53
 * Null or absent normalizes to 0 -> the app never has to reason about a missing count
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

// ── Per-scope builder ─────────────────────────────────────────────────────────

async function buildScope(
  sql: ReturnType<typeof getDb>,
  r2Bucket: R2Bucket,
  scope: string,
): Promise<ScopeResult> {

  let rows: ContentRow[];
  // THIS ORDER BY *IS* THE FEED ORDER, and it is the whole of it -> nothing re-sorts it in JS afterwards
  // The CMS ordering page reproduces the feed by COPYING this clause -> keep the two byte-for-byte in step
  // THREE TIERS: hand pins -> lifetime uses -> recency -> id. Each one only settles what the one above tied on
  // Tier 1 is `feed_rank`, a nullable column the CMS writes (restored 2026-09-02) -> NULLS LAST puts unpinned last
  // NULL means UNPINNED and is ~every row -> with nothing pinned this clause IS the use-count order it replaced
  // Never fold NULL to 0 -> 0 is a valid top pin -> and imports write no rank, so a bulk drop cannot displace the head
  // The trailing `id` is a TOTAL-ORDER tiebreaker, not decoration -> an import is one transaction
  // So a whole batch ties on `created_at`, and at zero data on the counter too -> the sort would not be total
  // Postgres may then return tied rows differently on any run -> a new plan, a parallel scan, a post-VACUUM heap
  // Pages are cut every PAGE_SIZE rows in RETURNED order -> that reshuffles which item lands on which page
  // The feed reorders under a scrolling user, and anyone mid-pagination can see an item twice or miss it
  // `sort_order` deliberately does NOT lead -> imports own it -> leading with it ordered the feed by import sequence
  // Pins do not live there either, and for the same reason -> an import would silently reset the curation
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
    if (scope === "ringtones") {
      if (!row["audio_key"]) {
        console.warn(`[build-catalog] skipping ringtone id=${row["id"]}: missing audio_key`);
        skipped++;
        return false;
      }
      return true;
    }
    console.warn(`[build-catalog] skipping unknown-scope row id=${row["id"]}`);
    skipped++;
    return false;
  });

  // ── The feed order ─────────────────────────────────────────────────────────
  // Already decided by the ORDER BY above -> validation only DROPS rows -> dropping preserves relative order
  // So the survivors are still in feed order and the ranks below stay contiguous, with no holes
  const orderedRows = validRows;

  // ── Strip private keys + columns the app never reads ───────────────────────
  // The whole catalog is drained before first paint -> every column is download weight -> keep the models' fields only
  // A dropped column is always-null or unread today -> re-add it to the keep-set the moment a model starts reading it
  // `category` is ALWAYS emitted -> it is the browse axis the feed chips filter on
  // `created_at` STAYS on both -> postgres.js emits ISO-8601 "…Z", which Dart's DateTime.parse consumes directly
  // Ringtone `mime` STAYS -> set-as-ringtone infers the file extension from it
  // `apply_count`/`set_count` are emitted as the lifetime number the CMS and older installs read
  // They are also what the ORDER BY sorted on -> but the app must NOT re-sort -> `feed_rank` already encodes it
  // `apply_score`/`set_score`/`scored_at` are DROPPED -> retired decay state, read by nothing
  // Emitting them would invite the app to re-derive an order -> never put them back in the page
  // `feed_rank` is COMPUTED here, never read off a row -> a sparse position (10, 20, 30 …) in the feed order
  // The comparator already shipped in every install sorts on that name -> this order reaches phones that never update
  // It works on category chips too -> a chip filters this page set, and filtering preserves relative order
  const publicRows = orderedRows.map((row, i) => {
    const r = { ...row } as Record<string, unknown>;
    // `fetch_types:false` returns an array column as the raw literal string -> the Flutter models cast `tags` to a List
    if ("tags" in r) r["tags"] = pgTextArrayToList(r["tags"]);

    r["feed_rank"] = rankFor(i);
    delete r["scored_at"];

    if (scope === "wallpapers") {
      r["apply_count"] = pgBigintToNumber(r["apply_count"]);
      for (const k of [
        "audio_key",
        "mime",
        "duration_ms",
        "width",
        "height",
        "bytes",
        "apply_score",
      ]) {
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

  // ── Write paginated "all" catalog ──────────────────────────────────────────
  // Track every key this build writes -> anything else under the scope is a page it no longer produces
  // build-catalog is otherwise write-only -> without this, a shrunk page count leaves an orphan serving deleted items
  const writtenKeys = new Set<string>();

  // Math.max(1, …) -> a zero-row scope still writes an explicit EMPTY all_1.json
  // The app's first-page fetch must get valid JSON -> a 404 there is ambiguous, and it means the build FAILED
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

  // The app filters by CATEGORY client-side over this ONE all_*.json set -> never write per-category or per-tag pages
  // A chip filters the same page set, so filtering preserves the feed order -> per-chip pages would let the two contradict

  // ── Delete orphaned pages this build did not (re)write ─────────────────────
  // Anything under catalog/<scope>/ this build did not write is stale -> a legacy tag page, or a now-too-high page number
  const deleted = await deleteOrphanedPages(r2Bucket, scope, writtenKeys);

  return { pages: totalPages, items: orderedRows.length, skipped, deleted };
}

/**
 * Delete catalog/<scope>/*.json objects the current build did NOT write. Returns the count deleted.
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
