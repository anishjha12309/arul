// Stage 0 — check a new drop against archive-index.json BEFORE spending any ffmpeg time.
//
// dedup.mjs answers "is this already in the library?" by hashing the LIVE catalog.
// This answers the question the library cannot: "have I already handled this clip?" —
// including clips that were imported and later DELETED, and clips that never shipped at
// all. Those leave no trace in the catalog, so without this they come back on every
// re-drop of the same Drive folder.
//
// Two signals, strongest first:
//   sha  — 64-bit content hash. A match means the byte-identical file was staged before;
//          this is a re-download, not a new clip.
//   dHash — perceptual, frame at 1s. Survives re-encode/re-cut of the same generation.
//
// Usage: node archive-check.mjs <srcDir> [--t 8] [--json]
import { readdirSync, readFileSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { createHash } from "crypto";
import { createRequire } from "module";
const require = createRequire("c:/Anish/Unified CMS/");
const sharp = require("sharp");

const SRC = process.argv[2];
const ti = process.argv.indexOf("--t");
const T = ti > -1 ? parseInt(process.argv[ti + 1], 10) : 8; // raw-vs-raw is a tighter
// comparison than dedup.mjs's raw-vs-cleaned 10, so the default threshold is lower.
const AS_JSON = process.argv.includes("--json");
if (!SRC) { console.error("usage: archive-check.mjs <srcDir> [--t 8] [--json]"); process.exit(2); }

const INDEX = join(import.meta.dirname, "archive-index.json");
const { clips } = JSON.parse(readFileSync(INDEX, "utf8"));
const VID = new Set([".mp4", ".mov", ".webm", ".mkv", ".m4v"]);

const ham = (a, b) => { let x = BigInt("0x" + a) ^ BigInt("0x" + b), c = 0; while (x) { c += Number(x & 1n); x >>= 1n; } return c; };
async function dhashBuf(buf) {
  const { data } = await sharp(buf).greyscale().resize(9, 8, { fit: "fill" }).raw().toBuffer({ resolveWithObject: true });
  let hash = 0n, bit = 0n;
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) { if (data[r * 9 + c] < data[r * 9 + c + 1]) hash |= (1n << bit); bit++; }
  return hash.toString(16).padStart(16, "0");
}
function frame(path) {
  for (const ss of ["1", "0"]) {
    try {
      const b = execFileSync("ffmpeg", ["-v", "error", "-ss", ss, "-i", path, "-frames:v", "1",
        "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "3", "pipe:1"],
        { maxBuffer: 1 << 26, stdio: ["ignore", "pipe", "ignore"] });
      if (b?.length) return b;
    } catch { /* next seek point */ }
  }
  return null;
}
const bySha = new Map(clips.map((c) => [c.s, c]));
// what happened to an archived clip: shipped and still live, shipped then removed, or never imported
const fate = (c) => c.live
  ? `IN LIBRARY as ${c.cat}/${c.t || c.id || c.lid}`
  : c.id ? `imported as ${c.t}, ROW SINCE DELETED — do not re-import without deciding why`
    : `staged but NEVER imported (nearest live item @${c.hd})`;

const files = readdirSync(SRC).filter((f) => VID.has(f.slice(f.lastIndexOf(".")).toLowerCase())).sort();
if (!files.length) { console.error(`no video files in ${SRC}`); process.exit(1); }

const rows = [];
for (const f of files) {
  const p = join(SRC, f);
  const s = createHash("sha256").update(readFileSync(p)).digest("hex").slice(0, 16);
  const buf = frame(p);
  const d = buf ? await dhashBuf(buf) : null;
  const exact = bySha.get(s) || null;
  let near = null;
  if (!exact && d) {
    let best = { h: 999, c: null };
    for (const c of clips) { if (!c.d) continue; const h = ham(d, c.d); if (h < best.h) best = { h, c }; }
    if (best.h <= T) near = best;
  }
  rows.push({ file: f, sha: s, dhash: d, exact, near });
}

if (AS_JSON) { console.log(JSON.stringify(rows, null, 2)); process.exit(0); }

const ex = rows.filter((r) => r.exact), nr = rows.filter((r) => !r.exact && r.near), fresh = rows.filter((r) => !r.exact && !r.near);
console.log(`checked ${rows.length} clip(s) in ${SRC} against ${clips.length} archived (threshold ${T})\n`);
if (ex.length) {
  console.log(`RE-DOWNLOAD — byte-identical to a clip already staged (${ex.length}):`);
  for (const r of ex) console.log(`  ${r.file}\n      was ${r.exact.n} — ${fate(r.exact)}`);
  console.log("");
}
if (nr.length) {
  console.log(`NEAR-DUP — perceptually matches a staged clip (${nr.length}):`);
  for (const r of nr) console.log(`  ${r.file}  @${r.near.h}\n      ~ ${r.near.c.n} — ${fate(r.near.c)}`);
  console.log("");
}
console.log(`NEW — no archive match (${fresh.length}):`);
for (const r of fresh) console.log(`  ${r.file}`);
console.log(`\nsummary: ${ex.length} re-download, ${nr.length} near-dup, ${fresh.length} new`);
console.log("dHash flags dark, low-detail frames that share only a silhouette — VIEW any near-dup before dropping it.");
