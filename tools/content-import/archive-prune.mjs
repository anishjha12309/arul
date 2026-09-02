// Reclaim the staging ROOT -> delete only media archive-index.json records AND that is confirmed live.
// A file goes only when its hash is in the index (the record survives) AND that record is stamped live=1.
// Anything unrecorded, or recorded but NOT in the library, is KEPT -> those are the only copies left.
// Run archive-index.mjs first -> a stale index leaves a file unrecorded, which is kept, not deleted.
// Dry run by default -> nothing is deleted without --apply.
//
// Usage: node archive-prune.mjs [--root c:/Anish/arul-import] [--apply]
import { readdirSync, statSync, readFileSync, unlinkSync, rmdirSync, existsSync } from "fs";
import { join, relative } from "path";
import { createHash } from "crypto";

const arg = (f, d) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : d; };
const ROOT = arg("--root", "c:/Anish/arul-import").replace(/\\/g, "/");
const APPLY = process.argv.includes("--apply");

const INDEX = join(import.meta.dirname, "archive-index.json");
if (!existsSync(INDEX)) { console.error(`no archive-index.json — run archive-index.mjs first`); process.exit(2); }
const { clips } = JSON.parse(readFileSync(INDEX, "utf8"));
const bySha = new Map(clips.map((c) => [c.s, c]));

const VID = new Set([".mp4", ".mov", ".webm", ".mkv", ".m4v"]);
const IMG = new Set([".jpg", ".jpeg", ".png", ".webp"]);
const SKIP_DIR = new Set(["node_modules", ".git"]);
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex").slice(0, 16);

function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) { if (!SKIP_DIR.has(e.name)) walk(join(dir, e.name), acc); continue; }
    const ext = e.name.slice(e.name.lastIndexOf(".")).toLowerCase();
    if (VID.has(ext) || IMG.has(ext)) acc.push(join(dir, e.name));
  }
  return acc;
}

const dirs = readdirSync(ROOT, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !SKIP_DIR.has(e.name)).map((e) => e.name).sort();
const files = dirs.flatMap((d) => walk(join(ROOT, d)));

const del = [], keep = [];
const stemOf = (n) => n.replace(/\.[^.]+$/, "");
// A thumbs/ file is derived from its sibling clip -> it follows that clip's verdict.
// Its own bytes are never in the index -> archive-index.mjs skips thumbs/ as derivative.
const clipVerdictForThumb = new Map();
for (const p of files) {
  const rel = relative(ROOT, p).replace(/\\/g, "/");
  const ext = p.slice(p.lastIndexOf(".")).toLowerCase();
  if (rel.includes("/thumbs/")) continue; // second pass, once clip verdicts are known
  const s = sha(p);
  const rec = bySha.get(s);
  const reason = !rec ? "NOT IN INDEX — run archive-index.mjs"
    : !rec.live ? (rec.id ? `NOT in library (was ${rec.t}, row deleted)` : "NOT in library — never imported")
      : null;
  (reason ? keep : del).push({ p, rel, bytes: statSync(p).size, rec, reason });
  clipVerdictForThumb.set(stemOf(rel.split("/").pop()), !reason);
  void ext; void IMG;
}
// Thumbs follow their clip -> an orphan thumb whose clip is already gone is derived scratch too.
for (const p of files) {
  const rel = relative(ROOT, p).replace(/\\/g, "/");
  if (!rel.includes("/thumbs/")) continue;
  const v = clipVerdictForThumb.get(stemOf(rel.split("/").pop()));
  const bytes = statSync(p).size;
  if (v === false) keep.push({ p, rel, bytes, reason: "thumb of a clip being kept" });
  else del.push({ p, rel, bytes, rec: null, reason: null });
}

const mb = (n) => (n / 1048576).toFixed(1) + " MB";
const byFolder = {};
for (const d of del) { const f = d.rel.split("/")[0]; byFolder[f] = byFolder[f] || { n: 0, b: 0 }; byFolder[f].n++; byFolder[f].b += d.bytes; }

console.log(`${APPLY ? "PRUNING" : "DRY RUN"} — ${ROOT}\n`);
console.log(`DELETE (in index + confirmed live in library): ${del.length} files, ${mb(del.reduce((a, x) => a + x.bytes, 0))}`);
for (const [f, v] of Object.entries(byFolder).sort((a, b) => b[1].b - a[1].b)) console.log(`   ${f.padEnd(22)} ${String(v.n).padStart(4)} files  ${mb(v.b).padStart(10)}`);
console.log(`\nKEEP: ${keep.length} files, ${mb(keep.reduce((a, x) => a + x.bytes, 0))}`);
for (const k of keep) console.log(`   ${k.rel}\n       ${k.reason}`);

if (!APPLY) { console.log(`\nNothing deleted. Re-run with --apply to delete.`); process.exit(0); }

// unlinkSync can no-op silently -> a run once reported 182 deletions and left 38 files, all with a U+2026 in the name.
// So confirm every delete by re-stat -> never assume it from a non-throwing call.
// Failures are collected and printed at the END -> never interleaved with progress.
let n = 0, freed = 0;
const failed = [];
for (const d of del) {
  try { unlinkSync(d.p); } catch (e) { if (e.code !== "ENOENT") { failed.push([d, e.code || e.message]); continue; } }
  if (existsSync(d.p)) { failed.push([d, "still present after unlink"]); continue; }
  n++; freed += d.bytes;
}
// Drop directories the prune emptied -> a folder still holding kept media survives.
for (const dir of dirs) {
  const full = join(ROOT, dir);
  for (const sub of ["thumbs", ""]) {
    const t = sub ? join(full, sub) : full;
    try { if (existsSync(t) && readdirSync(t).length === 0) { rmdirSync(t); console.log(`  removed empty dir ${relative(ROOT, t).replace(/\\/g, "/")}`); } } catch { /* not empty */ }
  }
}
console.log(`\ndeleted ${n} files, freed ${mb(freed)}`);
console.log(`kept ${keep.length} file(s) — the only copies of content not in the library.`);
if (failed.length) {
  console.log(`\nFAILED TO DELETE (${failed.length}) — re-run to retry:`);
  for (const [d, why] of failed) console.log(`  ${d.rel}\n      ${why}`);
  process.exitCode = 1;
}
