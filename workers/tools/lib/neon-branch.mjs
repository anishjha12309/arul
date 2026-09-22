/**
 * The ONE home for "which Neon branch is this tool about to read?".
 *
 * WHY THIS EXISTS: `.dev.vars` holds FOUR postgres strings — DATABASE_URL (production,
 * `ep-fancy-grass`), DEBUG_DATABASE_URL (the throwaway `debug` branch, `ep-wandering-dawn`) and the
 * two Hyperdrive local-override names, which also point at debug. A tool that grabs "the first
 * postgres:// in the file" therefore reads the DEBUG branch, because the Hyperdrive lines sit above
 * DATABASE_URL. `verify-debits.mjs` did exactly that and spent its life reporting on debug data: it
 * cried 209 STUCK subscriptions while production had zero. The dangerous direction is the other one
 * — that tool would have reported HEALTHY straight through a real billing outage, which is the
 * precise silent failure it was written to catch.
 *
 * So: select by NAME, never by position, and always say out loud which branch was opened.
 */
import fs from "node:fs";
import postgres from "postgres";

const DEV_VARS = new URL("../../.dev.vars", import.meta.url);

/** Endpoint prefix -> the name a human recognises, so the banner cannot be misread. */
const KNOWN = [
  ["ep-fancy-grass", "production"],
  ["ep-wandering-dawn", "debug branch"],
];

/**
 * Reads the named connection string out of `.dev.vars`.
 *
 * `useDebug` picks DEBUG_DATABASE_URL over DATABASE_URL — the same `--debug` flag the prod tools take.
 * Exits on a missing key: a tool that cannot name its target must not guess one.
 */
export function connectionString(useDebug = false) {
  const key = useDebug ? "DEBUG_DATABASE_URL" : "DATABASE_URL";
  // Matched line-by-line on the key PREFIX, with no regex over the value, on purpose. The regex form
  // needs escaped backslashes, and losing ONE turns [^\s"'] into [^s"'] — a class that excludes the
  // letter s, so the host truncates at its first s (ep-fancy-grass -> ep-fancy-gra) and the tool
  // connects nowhere. That cost a debugging round the day this file was written.
  for (const raw of fs.readFileSync(DEV_VARS, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line.startsWith(key + "=")) continue;
    let value = line.slice(key.length + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) value = value.slice(1, -1);
    if (value.startsWith("postgres")) return { key, url: value };
  }
  console.error(`No ${key} in workers/.dev.vars`);
  process.exit(2);
}

/** Host-only label for the banner — never the credentials, which must not reach a transcript. */
export function describe(url) {
  const host = new URL(url).host;
  const known = KNOWN.find(([prefix]) => host.startsWith(prefix));
  return known ? `${known[1]} (${host})` : host;
}

/**
 * Opens the branch and prints which one, because a read-only report against the wrong database is
 * indistinguishable from a correct one — the banner is what makes that visible without re-deriving it.
 */
export function openBranch({ useDebug = false, quiet = false } = {}) {
  const { key, url } = connectionString(useDebug);
  if (!quiet) console.log(`[db] ${key} -> ${describe(url)}\n`);
  return postgres(url, { ssl: "require", prepare: false, connect_timeout: 10 });
}
