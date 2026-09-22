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
// `--debug` targets the `debug` Neon branch (DEBUG_DATABASE_URL) instead of production (DATABASE_URL).
const useDebug = args.includes("--debug");
const statement = args.filter((a) => a !== "--write" && a !== "--debug")[0];

if (!statement || !statement.trim()) {
  console.error('usage: node tools/prod-sql.mjs [--write] [--debug] "<SQL>"');
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

// Named variable, not "the first postgres:// in the file" — .dev.vars holds several, and the debug
// branch must never be reachable by accident from a prod command or the other way round.
const key = useDebug ? "DEBUG_DATABASE_URL" : "DATABASE_URL";
const m = fs
  .readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
  .match(new RegExp(`^${key}=\\s*"?(postgres(?:ql)?:\\/\\/[^\\s"']+)`, "m"));
if (!m) {
  console.error(`No ${key} in workers/.dev.vars`);
  process.exit(1);
}

// The target word is the one signal a human reads before a write lands — keep it loud and exact.
if (isWrite) {
  console.warn(
    `[prod-sql] WRITING to ${useDebug ? "debug branch" : "production"}: ${stripped.slice(0, 120)}`,
  );
}

const sql = postgres(m[1], { ssl: "require", prepare: false, connect_timeout: 10 });
try {
  console.log(JSON.stringify(await sql.unsafe(stripped), null, 2));
} finally {
  await sql.end();
}
