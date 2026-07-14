/**
 * Neon Postgres client via Cloudflare Hyperdrive.
 *
 * Pattern from official docs:
 *   https://developers.cloudflare.com/hyperdrive/examples/connect-to-postgres/postgres-drivers-and-libraries/postgres-js/
 *
 * - Uses postgres.js ^3.4.5 (minimum required for Hyperdrive)
 * - Requires `nodejs_compat` flag in wrangler.toml
 * - env.HYPERDRIVE.connectionString provides the Hyperdrive-proxied URL
 * - max:5 keeps subrequest pool bounded per Worker invocation
 * - fetch_types:false avoids a round-trip on startup that is incompatible
 *   with the Workers runtime type-fetching mechanism
 * - prepare:true enables named prepared statements (supported by Hyperdrive)
 *
 * Usage:
 *   const sql = getDb(env);
 *   const rows = await sql`SELECT id FROM users WHERE google_sub = ${sub}`;
 *   ctx.waitUntil(sql.end());  // release connection at end of request
 */

import postgres from "postgres";
import type { Env } from "../env.js";

export function getDb(env: Env): postgres.Sql {
  return postgres(env.HYPERDRIVE.connectionString, {
    max: 5,
    fetch_types: false,
    prepare: true,
  });
}
