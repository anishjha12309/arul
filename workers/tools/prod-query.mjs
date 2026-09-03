/**
 * READ-ONLY production Neon query helper.
 *
 * Refuses anything that is not a single SELECT / WITH…SELECT. This is the tool
 * the permission allow-rule `Bash(node tools/prod-query.mjs*)` points at, so the
 * guard below is the actual security boundary — keep it strict.
 *
 * Connection string is read from workers/.dev.vars (never passed on the CLI, so
 * it cannot leak into shell history or a transcript).
 *
 *   cd workers && node tools/prod-query.mjs "SELECT count(*) FROM users"
 *
 * For writes use tools/prod-sql.mjs, which is separately permissioned.
 */
import fs from "node:fs";
import postgres from "postgres";

const args = process.argv.slice(2);
// `--debug` targets the `debug` Neon branch (DEBUG_DATABASE_URL) instead of production (DATABASE_URL).
const useDebug = args.includes("--debug");
const raw = args.filter((a) => a !== "--debug")[0];
if (!raw || !raw.trim()) {
  console.error('usage: node tools/prod-query.mjs [--debug] "SELECT …"');
  process.exit(2);
}

// ── Guard ────────────────────────────────────────────────────────────────────
// Strip comments first so `/* */ DELETE …` or `-- x\nDELETE …` cannot smuggle a
// write past the prefix test.
const stripped = raw
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/--[^\n]*/g, " ")
  .trim();

if (!/^(select|with)\b/i.test(stripped)) {
  console.error("REFUSED: prod-query.mjs runs SELECT/WITH only. Use tools/prod-sql.mjs for writes.");
  process.exit(1);
}
// One statement only — a trailing `; UPDATE …` must not ride along.
if (stripped.replace(/;\s*$/, "").includes(";")) {
  console.error("REFUSED: multiple statements. Run one SELECT at a time.");
  process.exit(1);
}
if (/\b(insert|update|delete|drop|truncate|alter|create|grant|revoke|copy)\b/i.test(stripped)) {
  console.error("REFUSED: write keyword present in a read-only query.");
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

const sql = postgres(m[1], { ssl: "require", prepare: false, connect_timeout: 10 });
try {
  console.log(JSON.stringify(await sql.unsafe(stripped), null, 2));
} finally {
  await sql.end();
}
