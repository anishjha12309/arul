/**
 * Publish pipeline shared by every CMS mutation.
 *
 * Each route writes the row AND bumps that app's app_config.content_version in
 * ONE transaction (so a crash can never publish a row without a version bump —
 * the app Worker's hourly cron would otherwise think nothing changed), then
 * calls triggerRebuild here to fire the app Worker's own rebuild endpoint:
 *
 *   POST {apiBase}/internal/build-catalog
 *   Authorization: Bearer {per-app catalog secret}
 *
 * A rebuild failure must NOT roll back the DB write — the route surfaces a
 * "rebuild failed, retry" banner instead, and the app Worker's hourly cron
 * self-heals (it sees content_version ahead of the built catalog and rebuilds).
 *
 * The boolean result also gates DESTRUCTIVE follow-ups: replaced/deleted media
 * objects are only removed from R2 after a confirmed rebuild, so a still-stale
 * catalog never points at missing bytes.
 */

import type { Env } from "./env.js";
import type { AppDef } from "./registry.js";

export const REBUILD_FAILED_MSG =
  "Saved, but the catalog rebuild failed — retry from App config; the hourly cron self-heals";

/** Fire the app Worker's rebuild endpoint. Returns true on 2xx. Never throws. */
export async function triggerRebuild(env: Env, app: AppDef): Promise<boolean> {
  try {
    // Service binding when available (plain fetch() to a sibling *.workers.dev
    // host is blocked as a same-zone worker-to-worker subrequest); the URL's
    // host is only advisory to the bound Worker.
    const doFetch = app.service(env)?.fetch.bind(app.service(env)) ?? fetch;
    const res = await doFetch(`${app.apiBase}/internal/build-catalog`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${app.catalogSecret(env)}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    });
    if (!res.ok) {
      console.error(`[cms/rebuild] ${app.slug} rebuild failed: HTTP ${res.status}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`[cms/rebuild] ${app.slug} rebuild error:`, err);
    return false;
  }
}
