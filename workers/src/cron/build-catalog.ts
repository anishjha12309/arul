/**
 * Catalog builder — generates the edge-cached catalog JSON from Neon.
 *
 * Logic:
 *   - Queries Neon for published rows (via Hyperdrive)
 *   - Validates: wallpapers need full_key; live wallpapers need video/mp4 mime;
 *     ringtones need audio_key
 *   - Strips private keys per scope:
 *       wallpapers → keep full_key (public preview) + category (the browse axis)
 *       ringtones  → keep audio_key + cover_key (public preview) + category
 *   - Paginates PAGE_SIZE/page with the exact catalog JSON shape
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

// The app drains a WHOLE catalog before rendering its feed (category
// filtering is client-side), so every extra page is user-visible first-paint
// latency. At 20/page that was measured on device: 8 serial round trips put
// the ringtone tab at ~5 s, and 32 pages held the wallpaper cold start (no
// disk snapshot yet) around 5 s even through a 4-wide drain pool. 200/page
// keeps ringtones to one page and today's 634 wallpapers to 4 (page 1 + one
// parallel batch); the app reads per_page/total_pages from the JSON, so the
// size is not a client contract.
const PAGE_SIZE = 200;

// Catalog pages are fetched with `?v=<content_version>` (a publish mints a new
// version, hence a new edge-cache key), so a page body is immutable for its
// key and can sit at the edge for a day. The old default (max-age=60) made the
// edge revalidate against R2 origin on nearly every real-world fetch — 0.5–1 s
// per page, with multi-second outliers. The only un-versioned fetch is the
// rare version.json-failed fallback, and a day bounds its staleness.
const CATALOG_PAGE_CACHE_CONTROL = "public, max-age=86400";

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
  [scope: string]:
    | ScopeResult
    | { error: string }
    | { skipped: "no_change" }
    | { skipped: "locked" };
}

// ── R2 binding name in wrangler.toml ─────────────────────────────────────────
// Writes go through the R2 Workers binding (env.R2, declared in wrangler.toml as
// [[r2_buckets]] binding = "R2" and typed in env.ts), not the S3 presign API —
// no outbound HTTP, no signing overhead.

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
  // ── Mutual exclusion ───────────────────────────────────────────────────────
  // Two builders must never run concurrently. The CMS fires a rebuild on EVERY
  // content mutation while the hourly cron rebuilds independently, so overlap is
  // routine during a bulk publish — and overlap is destructive here:
  //   · deleteOrphanedPages deletes every catalog/<scope>/*.json this build did
  //     not itself write, so a build that saw fewer items happily deletes a
  //     concurrent build's higher pages, leaving total_pages advertised while
  //     those pages 404;
  //   · writeVersionPointer is last-writer-wins, so an OLDER build finishing
  //     second rewinds version.json and every client pins a stale ?v=.
  // Best-effort KV lock: KV is eventually consistent so this is not a hard
  // mutex, but it collapses the common same-minute overlap, and the monotonic
  // guard in writeVersionPointer covers what slips through.
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

/** KV key + TTL for the build lock. TTL bounds a crashed build's stale lock. */
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
    // KV unavailable must not block content publishing — proceed unlocked
    // rather than freezing the catalog behind a broken lock.
    console.warn("[build-catalog] lock acquire failed, proceeding unlocked:", err);
    return true;
  }
}

async function releaseBuildLock(env: Env, holder: string): Promise<void> {
  try {
    // Only clear OUR lock — never delete one a later build acquired after ours
    // expired, or we'd hand it two concurrent writers again.
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
    // Read the dedicated app_config.content_version (bigint) column,
    // NOT feature_flags. Per docs/architecture.md §Catalog generation and db/schema/, the operator
    // or content editor bumps content_version on any content change; the cron
    // compares it against the last-built version stored in KV and skips unchanged scopes.
    // content_version is a bigint, so postgres.js may return it as a string —
    // normalize to a canonical string for comparison (avoids precision loss).
    //
    // RETRY ONCE. This Worker idles for hours (browse never touches the DB —
    // CLAUDE.md §2), so Neon suspends and Hyperdrive can hand this first query a
    // severed connection. That is a stale-pool artifact, not a real outage: a
    // second attempt gets a fresh connection and succeeds. Without the retry the
    // whole hour is skipped; with it the cron self-heals.
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
    // Falling through here used to be actively harmful. A null contentVersion
    // DISABLES the change-detection gate below, so the cron would go on to run a
    // full buildScope() — the most expensive thing it can do — against the very
    // connection that just failed, then skip writing version.json anyway (that
    // write is also gated on contentVersion). The result was a 30 s stall that
    // the runtime killed, taking the concurrently-scheduled autopay scan with
    // it. Bail out cheaply instead, and mark every requested scope errored so
    // the caller's anyScopeError guard correctly skips the canonical sweep.
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

    // ── Write the always-fresh version pointer LAST (commit marker) ───────────
    // The app reads catalog/version.json (served with a short edge TTL — see
    // VERSION_POINTER_CACHE_CONTROL) to learn the current content_version, then
    // appends ?v=<version> to every catalog fetch. Writing it only AFTER every
    // page body is durably in R2 — and only if no scope errored — means
    // advertising version N guarantees N's content already exists, so an app
    // that polls the pointer can never request a ?v=N page that isn't built yet.
    // See docs/architecture.md §4.2. (The purge backstop moved to the hsr-cms
    // worker on 2026-07-20 along with the rest of authoring.)
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
    // Release on EVERY path, including the early abort above. Mirrors the
    // try/finally autopay-notify.ts already uses.
    //
    // Swallow end()'s own rejection. The connection this run recovered from was
    // severed mid-flight, and tearing down a socket that is already gone can
    // itself reject — inside a `finally` that rejection REPLACES the return
    // value, turning a rebuild that fully succeeded (pages written, app_config
    // written) into a failed promise. The caller would then skip the canonical
    // sweep and log a rebuild failure that did not happen.
    await sql.end().catch(() => {});
  }
}

// ── Always-fresh version pointer ────────────────────────────────────────────

/**
 * Cache policy for the version pointer.
 *
 * `no-store` made this the ONE uncacheable request on the cold-start path: every
 * launch, for every user, went to origin — measured on the sibling Pakiza
 * deployment (identical zone/bucket setup) at a p50 of **240 ms across 20
 * requests, 20/20 cf-cache-status: DYNAMIC** — before a single catalog page
 * could be requested, because the `?v=` for those pages comes from here.
 *
 * A non-zero `max-age` is what actually gets this cached. The first attempt used
 * `max-age=0, s-maxage=30` to keep clients from holding their own copy — and
 * Cloudflare answered `cf-cache-status: DYNAMIC` on 12/12 requests at the same
 * 240 ms, ignoring the `s-maxage` entirely, while every sibling object on the
 * same bucket (`max-age=14400`) cached normally. `max-age=0` reads as "do not
 * cache" here, so the edge never gets to help.
 *
 * Holding it client-side is not a real risk: the app talks through
 * `package:http`, which implements no HTTP cache, so `max-age` only ever binds
 * the edge and any browser hitting the CDN directly.
 *
 * The cost is a bounded staleness window: for at most 30 s after a publish some
 * clients pin the previous `?v=` and get the previous — still valid, still
 * complete — catalog. They self-correct on the next poll.
 *
 * That trade is safe because the pointer is only ever a HINT about freshness,
 * never about correctness: writeVersionPointer runs last and only after every
 * page body is durably in R2, so an advertised version always exists. The
 * hsr-cms worker purges this key on publish (when CF_ZONE_ID/CF_PURGE_TOKEN are
 * set), which collapses the window to near-zero for the path that matters.
 *
 * Keep `stale-while-revalidate` well above `s-maxage`: it is what stops a burst
 * of cold starts from stampeding origin the instant the edge copy ages out.
 */
const VERSION_POINTER_CACHE_CONTROL =
  "public, max-age=30, stale-while-revalidate=300";

/**
 * Write catalog/version.json with the current content_version. This is the only
 * file the app must fetch near-fresh; everything else is keyed by ?v=<version>
 * and stays fully edge-cacheable.
 */
export async function writeVersionPointer(
  r2Bucket: R2Bucket,
  contentVersion: string,
): Promise<void> {
  // MONOTONIC: never advertise a version older than the one already published.
  // content_version only ever increases (the CMS bumps it in the same
  // transaction as the row write), so a lower value here means THIS build read
  // an older DB snapshot than a build that already finished. Writing it anyway
  // would rewind every client to a stale ?v= and hide freshly published content
  // until the next bump. Skip instead — the newer pointer is already correct,
  // and this build's pages were written under the same keys.
  //
  // Only a STRICTLY older version is refused. Re-writing the SAME version is
  // allowed on purpose: the object's stored Cache-Control is metadata, so a
  // policy change (or a corrupted/misheadered pointer) would otherwise be
  // unfixable until someone happened to publish content. Rewriting is idempotent
  // in everything that matters — content_version is unchanged, so no client's
  // ?v= moves; only built_at and the headers refresh.
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
    // Unreadable/corrupt pointer must not block a rebuild — treat as absent so
    // this build republishes it.
    return null;
  }
}

/**
 * True when `candidate` is strictly newer than `current`.
 *
 * content_version is a Postgres bigint, so compare NUMERICALLY — string
 * comparison would rank "9" above "10" and wedge the pointer at a single digit
 * forever. Non-numeric input (should never happen) falls back to "treat as
 * newer" so a malformed existing pointer can always be overwritten.
 */
export function isNewerVersion(candidate: string, current: string): boolean {
  const a = Number(candidate);
  const b = Number(current);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return true;
  return a > b;
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
  // The trailing `id` in both ORDER BYs is a TOTAL-ORDER tiebreaker, not
  // decoration. Content here arrives via bulk imports (one transaction per
  // batch), so whole batches share sort_order=0 AND an identical created_at.
  // Without a unique final key the sort is not total, and Postgres is free to
  // return tied rows in a different order on any run — a different plan, a
  // parallel scan, or simply a different heap layout after a VACUUM. Since
  // pages are cut every PAGE_SIZE rows in returned order, that silently reshuffles
  // which items land on which page between rebuilds: the feed reorders under
  // users for no reason, and anyone mid-pagination during a rebuild can see an
  // item twice or miss it entirely. `id` is unique, so appending it makes the
  // order reproducible forever.
  if (scope === "wallpapers") {
    // sort_order is no longer surfaced in the CMS (defaults to 0), so created_at
    // is the real tiebreaker — newest first within an equal sort_order.
    rows = await sql`
      SELECT * FROM wallpapers
      WHERE is_published = true
      ORDER BY sort_order ASC, created_at DESC, id ASC
    `;
  } else if (scope === "ringtones") {
    // Same ordering contract as wallpapers: sort_order ASC, created_at DESC —
    // newest first within an equal sort_order. NULLS LAST so a row with a null
    // created_at (shouldn't happen, but the column is only defaulted) sinks to
    // the end instead of leading the feed.
    rows = await sql`
      SELECT * FROM ringtones
      WHERE is_published = true
      ORDER BY sort_order ASC, created_at DESC NULLS LAST, id ASC
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

  // ── Strip private keys + columns the app never reads ───────────────────────
  // We keep ONLY what the Flutter models consume so catalog pages stay lean.
  // Required model fields (id, title, type, tags, full_key,
  // is_published, sort_order) are always retained. The dropped columns are
  // always-null or unread in v1; re-add to the keep-set if a model starts using one.
  //   wallpapers: drop mime, duration_ms, width, height, bytes
  //               (created_at STAYS — the app's "New" tab windows the feed to the
  //               last 7 days client-side; postgres.js emits it as an ISO-8601
  //               "…Z" string that Dart's DateTime.parse consumes directly.)
  //   ringtones:  drop duration_ms, bytes  (audio_key + cover_key stay — public
  //               preview/stream + cover rendering; mime stays — used to infer
  //               the file extension on set-as-ringtone; created_at STAYS.)
  //   `category` (the browse axis — feed chips filter on it) is always emitted.
  //   `feed_rank` (wallpapers only, usually null) is always emitted too: it IS
  //   the curated head of the app's All feed, so it has to ride inside the
  //   catalog JSON for a CMS save to reach users the way a publish does
  //   (version bump → rebuild → purge). Ordering here is unchanged — the app
  //   applies the rank in feedOrder().
  const publicRows = validRows.map((row) => {
    const r = { ...row } as Record<string, unknown>;
    // Normalize text[] columns: postgres.js (fetch_types:false, required for
    // Hyperdrive) returns array columns as the raw literal string e.g. "{Azaan}".
    // The Flutter models cast `tags` to List<dynamic>, so emit a real JSON array.
    if ("tags" in r) r["tags"] = pgTextArrayToList(r["tags"]);

    if (scope === "wallpapers") {
      // `category` (the browse axis) and `feed_rank` (the curated All head) are
      // emitted as-is; neither may ever be added to the drop list below.
      for (const k of ["audio_key", "mime", "duration_ms", "width", "height", "bytes"]) {
        delete r[k];
      }
      return r;
    }
    // ringtones — the only other scope. Keeps id, title, category, tags,
    // audio_key, cover_key, mime, is_published, sort_order, created_at.
    for (const k of ["full_key", "duration_ms", "bytes"]) {
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

  // Math.max(1, …) guarantees a zero-row scope still writes an explicit empty
  // all_1.json ({ total: 0, total_pages: 1, has_more: false, items: [] }) —
  // the app's first-page fetch must get valid JSON, never an ambiguous 404.
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
