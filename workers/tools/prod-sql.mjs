/**
 * Production Neon helper that CAN WRITE. Handle accordingly.
 *
 * Exists for the scenarios that genuinely need it — the grant/revoke
 * restore (subscription grant/revoke restore), tombstone checks, and cascade verification. For
 * reads use tools/prod-query.mjs, which refuses writes and is the safer default.
 *
 * A write requires the explicit --write flag, so a mistyped statement cannot
 * mutate production by accident:
 *
 *   node tools/prod-sql.mjs "SELECT …"                    # reads, no flag needed
 *   node tools/prod-sql.mjs --write "UPDATE subscriptions SET … WHERE …"
 *
 * Guard: a bare UPDATE/DELETE with no WHERE is always refused, flag or not.
 * Connection string comes from workers/.dev.vars, never the CLI.
 */
import fs from "node:fs";
import postgres from "postgres";

const args = process.argv.slice(2);
const allowWrite = args.includes("--write");
const statement = args.filter((a) => a !== "--write")[0];

if (!statement || !statement.trim()) {
  console.error('usage: node tools/prod-sql.mjs [--write] "<SQL>"');
  process.exit(2);
}

const stripped = statement
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .trim();

const isWrite = /\b(insert|update|delete|drop|truncate|alter|create|grant|revoke|copy)\b/i.test(
  stripped,
);

if (isWrite && !allowWrite) {
  console.error("REFUSED: that statement writes. Re-run with --write if you mean it.");
  process.exit(1);
}

// An unqualified UPDATE/DELETE is the classic way to wipe a table. Never allow
// it, even with --write — every legitimate restore in the test plan is scoped.
if (/^\s*(update|delete)\b/i.test(stripped) && !/\bwhere\b/i.test(stripped)) {
  console.error("REFUSED: UPDATE/DELETE without a WHERE clause.");
  process.exit(1);
}

const m = fs
  .readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
  .match(/postgres(?:ql)?:\/\/[^\s"']+/);
if (!m) {
  console.error("No postgres connection string found in workers/.dev.vars");
  process.exit(1);
}

if (isWrite) console.warn(`[prod-sql] WRITING to production: ${stripped.slice(0, 120)}`);

const sql = postgres(m[0], { ssl: "require", prepare: false, connect_timeout: 10 });
try {
  console.log(JSON.stringify(await sql.unsafe(stripped), null, 2));
} finally {
  await sql.end();
}
