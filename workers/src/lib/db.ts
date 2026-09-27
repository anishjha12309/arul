/**
 * https://developers.cloudflare.com/hyperdrive/examples/connect-to-postgres/postgres-drivers-and-libraries/postgres-js/
 * Hyperdrive needs postgres.js >= 3.4.5 and the `nodejs_compat` flag -> both are pinned in wrangler.toml
 * fetch_types:false -> skips a startup round-trip the Workers runtime cannot serve -> required, not a tuning knob
 * max:5 bounds the subrequest pool per invocation; prepare:true is safe because Hyperdrive supports named statements
 */

import postgres from "postgres";
import type { Env } from "../env.js";

/**
 * Connect timeout, seconds. LOAD-BEARING for the crons — postgres.js defaults it to 30.
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

/**
 * Render a string[] as a Postgres array LITERAL, for `= ANY(${toPgTextArray(xs)}::text[])`.
 * ALWAYS pair it with an explicit cast: the literal is sent as an untyped string, and `ANY()` needs
 * to know what it is looking at. An empty list renders `{}`, which matches nothing rather than
 * throwing — the callers rely on that.
 */
export function toPgTextArray(items: string[]): string {
  if (items.length === 0) return "{}";
  const esc = items.map((t) => `"${t.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`);
  return `{${esc.join(",")}}`;
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
