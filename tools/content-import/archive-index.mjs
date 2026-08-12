// Build archive-index.json — the durable record of every source clip that has passed
// through the staging ROOT, kept so the media itself can be deleted.
//
// WHY: the masters/ and normalized/ folders under ROOT are ~250 MB of .mp4 that is
// already shipped to R2. Deleting them is safe for the LIBRARY (refhash.mjs rebuilds
// refhashes.json from the live CDN catalog), but it would lose every trace of a source
// clip that was NEVER imported — a rejected dup, an off-size export, a QC failure. Those
// would silently come back on the next Drive drop. This index is that trace, at ~200
// bytes per clip instead of ~1.4 MB.
//
// Records, per clip: perceptual dHash (near-dup, survives re-encode), a 64-bit content
// hash (byte-exact re-download), dims/duration/bytes, which folder(s) it lived in, and
// the library row it became if it was imported.
//
// Usage: node archive-index.mjs [--root c:/Anish/arul-import] [--out <path>]
//        node archive-index.mjs --dry-run     # print the tally, write nothing
import { readdirSync, statSync, writeFileSync, readFileSync, existsSync } from "fs";
import { execFileSync } from "child_process";
import { join, relative } from "path";
import { createHash } from "crypto";
import { createRequire } from "module";
// sharp is borrowed from the hsr-cms checkout, same as refhash.mjs / dedup.mjs.
const require = createRequire("c:/Anish/Unified CMS/");
const sharp = require("sharp");

const arg = (f, d) => { const i = process.argv.indexOf(f); return i > -1 ? process.argv[i + 1] : d; };
const ROOT = (arg("--root", "c:/Anish/arul-import")).replace(/\\/g, "/");
const OUT = arg("--out", join(import.meta.dirname, "archive-index.json")).replace(/\\/g, "/");
const DRY = process.argv.includes("--dry-run");

const VID = new Set([".mp4", ".mov", ".webm", ".mkv", ".m4v"]);
const IMG = new Set([".jpg", ".jpeg", ".png", ".webp"]);
// Folder -> category. Scratch stages (drive/, normalized/) are overwritten every run, so
// they carry no category of their own; theirs is resolved from the import plan join below.
const FOLDER_CAT = {
  "masters-amman": "amman", "masters-amman-new": "amman", "drive-amman-0730": "amman",
  "masters-ayyappan": "ayyappan", "masters-ayyappa-new": "ayyappan",
  "masters-murugan": "murugan", "masters-perumal": "perumal",
  "masters-sivan": "sivan", "masters-sivan-new": "sivan",
  "masters-temples": "temples",
};
const SKIP_DIR = new Set(["node_modules", "thumbs", ".git"]);

// ---- hashes -----------------------------------------------------------------
// dHash exactly as refhash.mjs / dedup.mjs compute it, so the values are comparable
// across all three indexes.
async function dhashBuf(buf) {
  const { data } = await sharp(buf).greyscale().resize(9, 8, { fit: "fill" }).raw().toBuffer({ resolveWithObject: true });
  let hash = 0n, bit = 0n;
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) { if (data[r * 9 + c] < data[r * 9 + c + 1]) hash |= (1n << bit); bit++; }
  return hash.toString(16).padStart(16, "0");
}
// Frame at 1s to match the thumbnail clean-batch.mjs makes; falls back to frame 0 for
// clips shorter than that. `vf` optionally applies a cleaning geometry (see coverage).
function frameVF(path, vf) {
  for (const ss of ["1", "0"]) {
    try {
      const buf = execFileSync("ffmpeg", ["-v", "error", "-ss", ss, "-i", path, "-frames:v", "1",
        ...(vf ? ["-vf", vf] : []), "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "3", "pipe:1"],
        { maxBuffer: 1 << 26, stdio: ["ignore", "pipe", "ignore"] });
      if (buf?.length) return buf;
    } catch { /* try the next seek point */ }
  }
  return null;
}
const frame = (p) => frameVF(p, null);
const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex").slice(0, 16);

function probe(path) {
  try {
    const out = execFileSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
      "stream=width,height:format=duration", "-of", "json", path], { encoding: "utf8" });
    const j = JSON.parse(out);
    const s = j.streams?.[0] || {};
    const dur = parseFloat(j.format?.duration);
    return { w: s.width ?? null, h: s.height ?? null, ms: isFinite(dur) ? Math.round(dur * 1000) : null };
  } catch { return { w: null, h: null, ms: null }; }
}

// ---- walk -------------------------------------------------------------------
function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) { if (!SKIP_DIR.has(e.name)) walk(join(dir, e.name), acc); continue; }
    const ext = e.name.slice(e.name.lastIndexOf(".")).toLowerCase();
    if (VID.has(ext) || IMG.has(ext)) acc.push(join(dir, e.name));
  }
  return acc;
}

const dirs = readdirSync(ROOT, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !SKIP_DIR.has(e.name))
  .map((e) => e.name).sort();
const files = dirs.flatMap((d) => walk(join(ROOT, d)));
console.log(`scanning ${files.length} media files across ${dirs.length} folders under ${ROOT}`);

// ---- import-plan join: base -> shipped library row --------------------------
// plan-batch.mjs always writes import-plan.json, so each batch clobbered the last; the
// per-category copies that were saved are all the provenance there is. Missing plans are
// expected — the dHash match against the live catalog is the authoritative coverage check.
const plans = readdirSync(ROOT).filter((f) => /^import-plan.*\.json$/.test(f));
const byBase = new Map();
for (const p of plans) {
  try {
    for (const it of JSON.parse(readFileSync(join(ROOT, p), "utf8"))) {
      if (it?.base) byBase.set(it.base, { id: it.id, title: it.title, cat: it.category, key: it.full_key });
    }
  } catch (e) { console.log(`  ! unreadable plan ${p}: ${e.message}`); }
}
console.log(`import-plan provenance: ${byBase.size} bases from ${plans.length} plan file(s)`);

// stem() matches clean-batch.mjs so a master filename joins to the plan's `base`.
const stem = (f) => f.replace(/\.[^.]+$/, "").replace(/\s+\(\d+\)$/, "").replace(/[^a-zA-Z0-9_-]/g, "_");

// ---- build ------------------------------------------------------------------
// MERGE, never truncate. Once archive-prune.mjs has run, the media this index describes
// is GONE — a plain rebuild would scan the few survivors and silently drop the record of
// everything already deleted, which is the whole point of the file. Existing records are
// seeded first and are never removed; a re-scan only adds clips and fills in blanks.
const bySha = new Map();
if (existsSync(OUT)) {
  try {
    const prev = JSON.parse(readFileSync(OUT, "utf8"));
    for (const c of prev.clips || []) bySha.set(c.s, c);
    console.log(`merging into existing index: ${bySha.size} clip(s) already recorded`);
  } catch (e) { console.log(`! existing index unreadable, starting fresh: ${e.message}`); }
}
let i = 0, failed = 0, added = 0, dupCopies = 0;
for (const path of files) {
  i++;
  const rel = relative(ROOT, path).replace(/\\/g, "/");
  const folder = rel.split("/")[0];
  const name = path.split(/[\\/]/).pop();
  const ext = name.slice(name.lastIndexOf(".")).toLowerCase();
  const bytes = statSync(path).size;
  const s = sha(path);

  // Byte-identical copies across folders collapse to one record (masters-* are backups
  // of what drive/ held, so most clips exist twice).
  if (bySha.has(s)) {
    const r = bySha.get(s);
    if (!r.f.includes(folder)) r.f.push(folder);
    if (!r.cat && FOLDER_CAT[folder]) r.cat = FOLDER_CAT[folder];
    (r._paths ||= []).push(path);
    dupCopies++;
    continue;
  }

  const buf = IMG.has(ext) ? readFileSync(path) : frame(path);
  let d = null;
  if (buf) { try { d = await dhashBuf(buf); } catch { /* recorded as null below */ } }
  if (!d) { failed++; console.log(`  ! no frame/hash: ${rel}`); }
  const { w, h, ms } = VID.has(ext) ? probe(path) : { ...probe(path), ms: null };
  const hit = byBase.get(stem(name));

  const rec = { n: name, s, d, b: bytes, w, h, ms, f: [folder], cat: FOLDER_CAT[folder] || hit?.cat || null };
  if (hit) { rec.id = hit.id; rec.t = hit.title; }
  rec._paths = [path]; // stripped before write; the coverage pass needs to re-read the file
  bySha.set(s, rec);
  added++;
  if (i % 25 === 0 || i === files.length) console.log(`  [${i}/${files.length}]`);
}

// ---- coverage stamp: is this clip actually in the live library? --------------
// MUST happen here, while the media still exists. A raw master is watermarked 720x1280
// while the shipped thumb comes from the CLEANED 1024x1824 clip, and the Veo path crops
// 40 bottom rows first — so a raw-vs-shipped dHash is not a like-for-like comparison.
// Where the raw hash is not already close, re-extract the frame under each cleaning
// geometry and take the best. Category is NOT used to restrict the search: the pipeline's
// review step legitimately re-files a clip into another category.
const REF = join(ROOT, "refhashes.json");
if (existsSync(REF)) {
  const refs = JSON.parse(readFileSync(REF, "utf8")).filter((r) => r.dhash);
  const liveIds = new Set(refs.map((r) => r.id));
  const ham = (a, b) => { let x = BigInt("0x" + a) ^ BigInt("0x" + b), c = 0; while (x) { c += Number(x & 1n); x >>= 1n; } return c; };
  const SPEC = "scale=1024:1824:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:1824,setsar=1";
  const best = (d) => refs.reduce((b, r) => { const h = ham(d, r.dhash); return h < b.h ? { h, r } : b; }, { h: 999, r: null });
  console.log(`\ncoverage: matching ${bySha.size} clips against ${refs.length} live catalog items`);
  for (const rec of [...bySha.values()]) {
    // A verdict already stamped stands: it was reached while the clip was still on disk and
    // could be re-extracted under each cleaning geometry. Re-deriving it from the raw hash
    // alone would be strictly worse, and for a pruned clip there is no file left to read.
    if (rec.live !== undefined && !rec._paths) continue;
    if (rec.id && liveIds.has(rec.id)) { rec.live = 1; rec.hd = 0; continue; } // plan UUID still in catalog
    let b = rec.d ? best(rec.d) : { h: 999, r: null };
    if (b.h > 6) {
      const path = [...(rec._paths || [])][0];
      for (const vf of [SPEC, `crop=iw:1240:0:0,${SPEC}`]) {
        if (!path || !existsSync(path)) break;
        const buf = frameVF(path, vf);
        if (!buf) continue;
        try { const c = best(await dhashBuf(buf)); if (c.h < b.h) b = c; } catch { /* keep current best */ }
      }
    }
    rec.hd = b.h === 999 ? null : b.h;
    // 10 is dedup.mjs's "already in storage" threshold, reused here for the same question.
    if (b.h <= 10) { rec.live = 1; if (!rec.id && b.r) rec.lid = b.r.id; }
    else rec.live = 0;
  }
  const nl = [...bySha.values()].filter((r) => !r.live);
  console.log(`  in library: ${bySha.size - nl.length}   NOT in library: ${nl.length}`);
  for (const r of nl) console.log(`  ! ${(r.cat || "?").padEnd(9)} nearest=${r.hd}  ${r.n}${r.t ? `  [was ${r.t}, row since deleted]` : ""}`);
}
for (const r of bySha.values()) delete r._paths;

const recs = [...bySha.values()].sort((a, b) => a.n.localeCompare(b.n));
const tally = recs.reduce((a, r) => (a[r.cat || "?"] = (a[r.cat || "?"] || 0) + 1, a), {});
console.log(`\nunique clips recorded: ${recs.length} (${added} added from ${files.length} file(s) scanned; ${dupCopies} byte-identical copy/copies collapsed)`);
console.log(`no dHash: ${failed}`);
console.log(`by category: ${Object.entries(tally).map(([k, v]) => `${k}=${v}`).join(", ")}`);
console.log(`with import provenance: ${recs.filter((r) => r.id).length}`);

if (DRY) { console.log("\n--dry-run: nothing written"); process.exit(0); }

// Minified on purpose: this file is the permanent stand-in for 250 MB of media, and it is
// read by tools, not by eye. archive-check.mjs pretty-prints what it matches.
const payload = {
  v: 1,
  note: "Durable record of source clips staged under arul-import; the media itself was deleted. d=dHash(frame@1s), s=sha256-64, b=bytes, f=folders, cat=category, id/t=shipped library row.",
  built: new Date().toISOString().slice(0, 10),
  root: ROOT,
  clips: recs,
};
writeFileSync(OUT, JSON.stringify(payload));
console.log(`\nwrote ${OUT} (${(statSync(OUT).size / 1024).toFixed(1)} KB)`);
