/**
 * Neon Postgres client via Cloudflare Hyperdrive.
 * https://developers.cloudflare.com/hyperdrive/examples/connect-to-postgres/postgres-drivers-and-libraries/postgres-js/
 *
 * Hyperdrive needs postgres.js >= 3.4.5 and the `nodejs_compat` flag -> both are pinned in wrangler.toml
 * fetch_types:false -> skips a startup round-trip the Workers runtime cannot serve -> required, not a tuning knob
 * max:5 bounds the subrequest pool per invocation; prepare:true is safe because Hyperdrive supports named statements
 * Every caller must `ctx.waitUntil(sql.end())` -> an unreleased connection outlives the request
 */

import postgres from "postgres";
import type { Env } from "../env.js";

/**
 * Connect timeout, seconds. LOAD-BEARING for the crons — postgres.js defaults it to 30.
 *
 * Browse never touches the DB -> the Worker idles for hours -> Neon suspends and the pooled socket goes stale
 * The next cron's first query lands on a severed socket -> a 30 s reconnect wait outlives the invocation
 * That killed the catalog rebuild AND the autopay scan in one go -> 5 s, comfortably above a healthy connect
 * It does NOT cover a pooled socket that is already dead: there is no connect to time out
 * That path fails as `write CONNECTION_CLOSED` after ~15 s -> only each cron's retry-once recovers it
 */
const CONNECT_TIMEOUT_SECONDS = 5;

/**
 * Coerce a Postgres timestamptz to a Date, fail-closed.
 *
 * `fetch_types:false` -> a timestamptz arrives as a Date OR an ISO-8601 string by driver path -> never assume one
 * Anything unparseable becomes null -> callers must read null as "no live period" / "not due"
 * Entitlement in payments.ts and debit-due in the autopay cron must read timestamps identically -> one copy, here
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
  // The verify-payments harness serves Postgres from PGlite -> exactly ONE client connection is accepted
  // A concurrent route (`/auth/login` Promise.alls two queries) opens a second -> PGlite drops the first
  // That surfaces as `Network connection lost` and a 500 that reads like an app bug -> pin the pool to 1
  // A Hyperdrive connection string never points at 127.0.0.1:5433 -> loopback-only -> production keeps the real pool
  const isLocalHarness = connectionString.includes("127.0.0.1:5433");
  return postgres(connectionString, {
    max: isLocalHarness ? 1 : 5,
    fetch_types: false,
    prepare: true,
    connect_timeout: CONNECT_TIMEOUT_SECONDS,
  });
}
