/**
 * Publish pipeline shared by every CMS mutation.
 *
 * The route writes the row AND bumps
 * app_config.content_version in ONE transaction, then calls rebuildAndPurge to
 * regenerate the affected catalog scope and evict the edge version pointer.
 *
 * The version bump lives in the caller's transaction (so a crash can't publish a
 * row without bumping the version, which would leave the hourly cron thinking
 * nothing changed). This module owns only the rebuild + cache eviction.
 */

import type { Env } from "../env.js";
import { buildCatalog } from "../cron/build-catalog.js";

/**
 * Force-rebuild a catalog scope (or all) then evict the edge version pointer.
 * THROWS if any rebuilt scope failed, so the caller can avoid destructive
 * follow-ups (e.g. deleting the replaced media) when the catalog isn't actually
 * regenerated. build-catalog itself withholds the version pointer on failure, so
 * a thrown error means the catalog stayed on the previous version (cron self-heals).
 */
export async function rebuildAndPurge(env: Env, scope: string | null): Promise<void> {
  const results = await buildCatalog(env, scope, true);
  const failed = Object.entries(results)
    .filter(([, r]) => r && typeof r === "object" && "error" in r)
    .map(([s]) => s);
  if (failed.length > 0) {
    throw new Error(`catalog rebuild failed for scope(s): ${failed.join(", ")}`);
  }
  await purgeVersionPointer(env);
}

/**
 * rebuildAndPurge that reports success as a boolean instead of throwing — for
 * routes that must branch (skip an old-key delete, warn the operator) on failure.
 */
export async function rebuildOk(env: Env, scope: string | null): Promise<boolean> {
  try {
    await rebuildAndPurge(env, scope);
    return true;
  } catch (err) {
    console.error("[admin/publish] rebuild failed:", err);
    return false;
  }
}

/**
 * Evict catalog/version.json from Cloudflare's edge cache so the app's
 * always-fresh pointer reflects the new content_version immediately.
 *
 * ONLY the version pointer needs purging: it is the single always-fresh file the
 * app reads before every catalog fetch (build-catalog writes it no-store; this is
 * a belt-and-suspenders eviction). Every OTHER catalog page is regenerated in R2
 * by build-catalog itself (which now also DELETES orphaned pages — see
 * cron/build-catalog.ts), so the freshly-written bytes are served directly. A
 * blanket per-page purge here is neither needed nor correct: Cloudflare's `files`
 * param does not accept wildcards (that needs the separate `prefixes` param), and
 * the pages are read live from R2 anyway (Cf-Cache-Status: DYNAMIC).
 *
 * Optional: only runs when CF_ZONE_ID + CF_PURGE_TOKEN are configured. Single-file
 * purge is free on all Cloudflare plans.
 */
export async function purgeVersionPointer(env: Env): Promise<void> {
  if (!env.CF_ZONE_ID || !env.CF_PURGE_TOKEN) return;
  const base = env.R2_CDN_BASE_URL.replace(/\/$/, "");
  try {
    const res = await fetch(
      `https://api.cloudflare.com/client/v4/zones/${env.CF_ZONE_ID}/purge_cache`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.CF_PURGE_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ files: [`${base}/catalog/version.json`] }),
      },
    );
    if (!res.ok) {
      console.warn("[admin/publish] cache purge failed:", res.status, await res.text());
    }
  } catch (err) {
    console.warn("[admin/publish] cache purge error:", err);
  }
}
