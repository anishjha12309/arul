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
 * - connect_timeout:5 — see below. LOAD-BEARING for the crons.
 *
 * Usage:
 *   const sql = getDb(env);
 *   const rows = await sql`SELECT id FROM users WHERE google_sub = ${sub}`;
 *   ctx.waitUntil(sql.end());  // release connection at end of request
 */

import postgres from "postgres";
import type { Env } from "../env.js";

/**
 * Connect timeout, in seconds.
 *
 * postgres.js defaults this to **30** (`postgres/src/index.js`, defaults). That
 * default is longer than a scheduled invocation can afford: this Worker is idle
 * for hours at a time (browse never touches the DB — CLAUDE.md §2), so Neon
 * suspends and Hyperdrive's pooled connection goes stale. The next cron's first
 * query then lands on a severed socket and postgres.js sits in its reconnect
 * wait for the full 30 s — long enough for the runtime to terminate the whole
 * invocation, taking the catalog rebuild AND the autopay scan down with it.
 * Observed in production 2026-07-27T01:00:03Z: wallTime 30017 ms, cpuTime 19 ms,
 * outcome "exception".
 *
 * 5 s is comfortably above a healthy Hyperdrive connect.
 *
 * NOTE what this does NOT cover, measured 2026-07-27T03:00:03Z: when Hyperdrive
 * hands back a pooled socket that is already dead, there is no *connect* to time
 * out — the first write fails as `write CONNECTION_CLOSED` after ~15 s, and this
 * setting has no effect on it. The retry-once in each cron is what recovers from
 * that; this bound only helps when the connect itself is the slow part.
 */
const CONNECT_TIMEOUT_SECONDS = 5;

/**
 * Coerce a Postgres timestamptz to a Date, fail-closed.
 *
 * postgres.js runs with `fetch_types:false` here (required for Hyperdrive), so a
 * timestamptz can arrive as either a real Date or an ISO-8601 string depending
 * on the driver path — never assume one. Anything unparseable becomes null,
 * which callers must treat as "no live period" / "not due".
 *
 * Lives here rather than beside one caller because entitlement decisions in
 * payments.ts and debit-due decisions in the autopay cron must read timestamps
 * identically; two copies of this would eventually disagree.
 */
export function toDate(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value !== "string") return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function getDb(env: Env): postgres.Sql {
  const connectionString = env.HYPERDRIVE.connectionString;
  // The verify-payments harness serves Postgres from PGlite, which accepts
  // exactly ONE client connection at a time. Any route that runs queries
  // concurrently (`/auth/login` does `Promise.all([insertUser,
  // lookupTombstone])`) makes postgres.js open a second connection, and PGlite
  // drops the first — surfacing as `Network connection lost` and a 500 that
  // looks like an app bug. Pinning the pool to 1 makes postgres.js queue those
  // queries on the single connection instead. Loopback-only by construction:
  // a Hyperdrive connection string never points at 127.0.0.1:5433 in any
  // deployed environment, so production keeps the real pool.
  const isLocalHarness = connectionString.includes("127.0.0.1:5433");
  return postgres(connectionString, {
    max: isLocalHarness ? 1 : 5,
    fetch_types: false,
    prepare: true,
    connect_timeout: CONNECT_TIMEOUT_SECONDS,
  });
}
