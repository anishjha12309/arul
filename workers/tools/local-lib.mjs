/**
 * Shared guards for the local stack tools (docs/local-stack.md): local-stack, local-seed-statuses, local-premium.
 * Every guard FAILS CLOSED: a tool that cannot prove it is aimed at the debug branch / local storage exits.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import postgres from "postgres";
import { connectionString } from "./lib/neon-branch.mjs";

export const WORKERS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const REPO_DIR = path.resolve(WORKERS_DIR, "..");
export const CMS_DIR = "C:/Anish/Unified CMS";
export const CDN_DIR = path.join(WORKERS_DIR, "tools", "local-cdn");
export const WRANGLER_JS = path.join(WORKERS_DIR, "node_modules", "wrangler", "bin", "wrangler.js");
export const DEFAULT_PERSIST = path.join(REPO_DIR, ".wrangler", "local-stack");
export const BUCKET = "south-indian-wallpapers";

export const PORTS = { worker: 8787, cdn: 8788, cms: 8790 };
export const WORKER_URL = `http://127.0.0.1:${PORTS.worker}`;
export const CDN_URL = `http://127.0.0.1:${PORTS.cdn}`;

/**
 * The Neon `debug` branch's ONE endpoint (project curly-thunder-28798436, branch br-crimson-surf-ao15eze3, per
 * the Neon API). Matched exactly, pooler suffix stripped -> any other host refuses.
 */
export const DEBUG_ENDPOINT = "ep-wandering-dawn-ao9e2q4g";
const PROD_ENDPOINT_PREFIX = "ep-fancy-grass";

/** Exit 1 = ran and refused (.claude/rules/scripts.md). */
export function refuse(msg) {
  console.error(`REFUSED: ${msg}`);
  process.exit(1);
}

/** Any flag that names remote storage is refused outright, before anything else runs. */
export function refuseRemoteFlags(argv) {
  for (const a of argv) {
    if (a === "--remote" || a === "-r" || a.startsWith("--remote=")) {
      refuse(
        "--remote targets PRODUCTION storage. The local stack tools write local R2 and the debug branch only.",
      );
    }
  }
}

export function endpointOf(url) {
  let host;
  try {
    host = new URL(url).hostname;
  } catch {
    return "";
  }
  return host.split(".")[0].replace(/-pooler$/, "");
}

/** Throws (via refuse) unless `url` is the debug endpoint AND not the production endpoint. */
export function assertDebugUrl(url, label) {
  const ep = endpointOf(url);
  if (!ep) refuse(`${label}: no parseable host in the connection string.`);
  if (ep.startsWith(PROD_ENDPOINT_PREFIX)) refuse(`${label} points at PRODUCTION (${ep}).`);
  const prodEp = endpointOf(connectionString(false).url);
  if (ep === prodEp) refuse(`${label} is the same endpoint as DATABASE_URL (production).`);
  if (ep !== DEBUG_ENDPOINT) refuse(`${label} endpoint ${ep} is not the debug branch (${DEBUG_ENDPOINT}).`);
  return ep;
}

/** The verified debug-branch connection string (pooler endpoint, the one wrangler dev uses for HYPERDRIVE). */
export function debugUrl() {
  const { url } = connectionString(true);
  assertDebugUrl(url, "DEBUG_DATABASE_URL");
  return url;
}

/** The ONLY way these tools open a database for writing. */
export function openDebugForWrite() {
  const url = debugUrl();
  console.log(`[db] debug branch (${endpointOf(url)}) — writes allowed here, nowhere else`);
  return postgres(url, { ssl: "require", prepare: false, connect_timeout: 10, onnotice: () => {} });
}

/** One key out of workers/.dev.vars, matched by prefix (no regex over the value — see neon-branch.mjs). */
export function devVar(key) {
  return fileVar(path.join(WORKERS_DIR, ".dev.vars"), key);
}

/** One key out of a dotenv file, "" when the file or key is absent. */
export function fileVar(file, key) {
  if (!fs.existsSync(file)) return "";
  for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line.startsWith(key + "=")) continue;
    let value = line.slice(key.length + 1).trim();
    if (value.startsWith('"') || value.startsWith("'")) value = value.slice(1, -1);
    return value;
  }
  return "";
}

/** Resolves --persist-to and refuses anything that is not a plain local directory path. */
export function persistDir(value) {
  const dir = path.resolve(value || DEFAULT_PERSIST);
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(dir)) refuse(`--persist-to must be a local directory, got ${dir}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

/** The env file `local-stack up` hands the Worker; it carries the CMS's build secret (see writeWorkerEnv). */
export const WORKER_ENV_FILE = path.join(DEFAULT_PERSIST, "worker.env");

/** Asks the local Worker to rebuild the catalog into LOCAL R2. The URL is hard-wired to loopback. */
export async function triggerLocalBuild() {
  const secret = fileVar(WORKER_ENV_FILE, "CATALOG_BUILD_SECRET") || devVar("CATALOG_BUILD_SECRET");
  if (!secret) refuse("no CATALOG_BUILD_SECRET in workers/.dev.vars");
  const url = `${WORKER_URL}/internal/build-catalog`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(120_000),
    });
    const text = await res.text();
    console.log(`[build] POST ${url} -> HTTP ${res.status} ${text.slice(0, 600)}`);
    return res.ok;
  } catch (err) {
    console.error(
      `[build] local Worker unreachable at ${WORKER_URL} (${err?.message ?? err}). Start it: node tools/local-stack.mjs up`,
    );
    return false;
  }
}
