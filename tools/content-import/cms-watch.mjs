// Watch both Workers involved in a CMS upload and fish the result for errors.
// A batch upload touches three places and only two of them log:
//   1. POST /admin/arul/wallpapers/media/upload-url   -> hsr-cms  (presign)
//   2. PUT  <presigned R2 url>                        -> browser to R2 DIRECT, in NO Worker log
//   3. POST /admin/arul/wallpapers (batch create)     -> hsr-cms QC + one Neon txn -> arul-api /internal/build-catalog
// Bytes failing to land is step 2 -> no Worker ever sees it -> check the browser Network tab.
// A QC rejection is NOT logged -> the handler 302s to `…/new?err=…` -> the reason shows in the CMS's red banner.
// ONE bad file rejects the WHOLE batch -> no rows inserted and every uploaded object deleted.
// A silent tail plus a red banner is a QC rejection, not a missing log.
//
// Usage:
//   node cms-watch.mjs                # tail both workers until Ctrl-C
//   node cms-watch.mjs --report       # summarise what the tails captured
import { spawn } from "child_process";
import { mkdirSync, createWriteStream, existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";

const arg = (f, d) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : d; };
const OUT = arg("--out", "c:/Anish/arul-import/cms-logs").replace(/\\/g, "/");
const REPORT = process.argv.includes("--report");

const TARGETS = [
  { name: "hsr-cms", cwd: "c:/Anish/Unified CMS" },
  { name: "arul-api", cwd: "c:/Anish/Arul/workers" },
];

// ── report mode ───────────────────────────────────────────────────────────────
if (REPORT) {
  if (!existsSync(OUT)) { console.error(`no logs at ${OUT} — run the watcher first`); process.exit(2); }
  let total = 0;
  const bad = [];
  for (const f of readdirSync(OUT).filter((f) => f.endsWith(".jsonl"))) {
    for (const line of readFileSync(join(OUT, f), "utf8").split("\n")) {
      if (!line.trim()) continue;
      let e; try { e = JSON.parse(line); } catch { continue; }
      total++;
      const status = e.event?.response?.status ?? null;
      const logs = (e.logs || []).filter((l) => l.level === "error" || l.level === "warn");
      const isBad = (e.outcome && e.outcome !== "ok") || (e.exceptions || []).length > 0 ||
        logs.length > 0 || (status !== null && status >= 400);
      if (isBad) bad.push({ f, e, status, logs });
    }
  }
  console.log(`${total} request(s) captured across ${TARGETS.length} worker(s); ${bad.length} with a problem\n`);
  for (const { f, e, status, logs } of bad) {
    const url = e.event?.request?.url || e.event?.cron || "(non-http event)";
    const method = e.event?.request?.method || "";
    console.log(`[${f.replace(".jsonl", "")}] ${e.outcome} ${status ?? ""} ${method} ${url}`);
    for (const x of e.exceptions || []) console.log(`    EXCEPTION ${x.name}: ${x.message}`);
    for (const l of logs) console.log(`    ${l.level.toUpperCase()} ${(l.message || []).join(" ")}`);
  }
  if (!bad.length) {
    console.log("No worker-side errors. If the CMS showed a red banner anyway, it was a QC");
    console.log("rejection (302 + ?err=…, deliberately not logged) — read the banner text.");
  }
  process.exit(0);
}

// ── watch mode ────────────────────────────────────────────────────────────────
mkdirSync(OUT, { recursive: true });
console.log(`tailing ${TARGETS.map((t) => t.name).join(" + ")} → ${OUT}`);
console.log(`Ctrl-C to stop, then: node cms-watch.mjs --report\n`);

// `wrangler tail --format json` emits PRETTY-PRINTED objects, not JSONL -> a line reader captures only the opening "{".
// So split the stream by brace depth, ignoring braces inside strings -> re-emit each event as one compact JSONL line.
function makeSplitter(onEvent) {
  let buf = "";
  return (chunk) => {
    buf += chunk;
    let depth = 0, inStr = false, esc = false, start = -1, cut = 0;
    for (let i = 0; i < buf.length; i++) {
      const ch = buf[i];
      if (inStr) {
        if (esc) esc = false;
        else if (ch === "\\") esc = true;
        else if (ch === '"') inStr = false;
        continue;
      }
      if (ch === '"') { inStr = true; continue; }
      else if (ch === "{") { if (depth === 0) start = i; depth++; }
      else if (ch === "}") {
        depth--;
        if (depth === 0 && start >= 0) { onEvent(buf.slice(start, i + 1)); cut = i + 1; start = -1; }
      }
    }
    buf = buf.slice(cut);
    if (buf.length > (8 << 20)) buf = ""; // never grow without bound on malformed input
  };
}

// A `wrangler tail` session is not durable -> Cloudflare expires it and the CLI exits 0, looking like a clean stop.
// An expired tail during an upload is worse than no tail -> the log stays silent and reads as "no errors".
// So respawn until asked to stop, and say so loudly in the log.
let stopping = false;
const children = [];
const logs = new Map();
function spawnTail(t) {
  if (!logs.has(t.name)) logs.set(t.name, createWriteStream(join(OUT, `${t.name}.jsonl`), { flags: "a" }));
  const log = logs.get(t.name);
  // One command string, not an argv array -> `npx` is a .cmd shim on Windows, so a shell is required.
  // Passing args alongside shell:true is deprecated -> keep them inside the string.
  const p = spawn(`npx wrangler tail ${t.name} --format json`, { cwd: t.cwd, shell: true });
  children.push(p);
  const split = makeSplitter((raw) => {
    let e; try { e = JSON.parse(raw); } catch { return; }
    log.write(JSON.stringify(e) + "\n");
    const status = e.event?.response?.status ?? "";
    const errLogs = (e.logs || []).filter((l) => l.level === "error" || l.level === "warn");
    const flag = (e.outcome && e.outcome !== "ok") || (e.exceptions || []).length ||
      errLogs.length || (status && status >= 400);
    const url = (e.event?.request?.url || "").replace(/^https?:\/\/[^/]+/, "") || e.event?.cron || "";
    console.log(`${flag ? "!!" : "  "} [${t.name}] ${status} ${e.event?.request?.method || ""} ${url}`);
    for (const x of e.exceptions || []) console.log(`      EXCEPTION ${x.name}: ${x.message}`);
    for (const l of errLogs) console.log(`      ${l.level.toUpperCase()} ${(l.message || []).join(" ")}`);
  });
  p.stdout.on("data", (b) => split(String(b)));
  p.stderr.on("data", (b) => { const s = String(b).trim(); if (s) console.log(`[${t.name}/wrangler] ${s}`); });
  p.on("exit", (code) => {
    if (stopping) return;
    console.log(`!! [${t.name}] tail EXITED (${code}) — session expired, respawning in 3s`);
    setTimeout(() => { if (!stopping) spawnTail(t); }, 3000);
  });
}
for (const t of TARGETS) spawnTail(t);

const stop = () => { stopping = true; for (const p of children) { try { p.kill(); } catch { /* already gone */ } } process.exit(0); };
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
