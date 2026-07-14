/**
 * Neon Postgres client via Cloudflare Hyperdrive — one Hyperdrive PER APP,
 * resolved through the registry so a route can only reach the DB of the app
 * it was mounted for.
 *
 * Same postgres.js settings as the shipped per-app Workers:
 * - max:5 keeps the subrequest pool bounded per invocation
 * - fetch_types:false avoids the startup round-trip that breaks on Workers
 * - prepare:true — named prepared statements (supported by Hyperdrive)
 *
 * Usage:
 *   const sql = getDb(env, app);
 *   …
 *   ctx.waitUntil(sql.end());  // release connection at end of request
 */

import postgres from "postgres";
import type { Env } from "../env.js";
import type { AppDef } from "../registry.js";

export function getDb(env: Env, app: AppDef): postgres.Sql {
  return postgres(app.hyperdrive(env).connectionString, {
    max: 5,
    fetch_types: false,
    prepare: true,
  });
}
