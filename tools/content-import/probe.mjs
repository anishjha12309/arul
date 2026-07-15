// Stage A — probe every Drive file (ffprobe) + collapse intra-batch exact dupes (sha256).
// Writes inventory.json; prints a terse summary only.
import { readdirSync, statSync, readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { execFileSync } from "child_process";
import { join, extname } from "path";

const DIR = "c:/Anish/arul-import/drive";
const IMG = new Set([".jpg", ".jpeg", ".png", ".webp"]);
const VID = new Set([".mp4", ".mov", ".webm", ".mkv", ".m4v"]);

function ffprobe(file) {
  const out = execFileSync("ffprobe", [
    "-v", "error", "-show_streams", "-show_format", "-of", "json", file,
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(out);
}

const files = readdirSync(DIR).filter((f) => {
  const e = extname(f).toLowerCase();
  return IMG.has(e) || VID.has(e);
});

const items = [];
const errors = [];
for (const f of files) {
  const path = join(DIR, f);
  const ext = extname(f).toLowerCase();
  const kind = IMG.has(ext) ? "image" : "video";
  const bytes = statSync(path).size;
  const sha256 = createHash("sha256").update(readFileSync(path)).digest("hex");
  let width = null, height = null, durationS = null, hasAudio = false, vcodec = null;
  try {
    const p = ffprobe(path);
    const v = (p.streams || []).find((s) => s.codec_type === "video");
    hasAudio = (p.streams || []).some((s) => s.codec_type === "audio");
    if (v) { width = v.width ?? null; height = v.height ?? null; vcodec = v.codec_name ?? null; }
    durationS = p.format?.duration ? Math.round(parseFloat(p.format.duration) * 10) / 10 : null;
  } catch (e) {
    errors.push({ file: f, error: String(e.message || e).slice(0, 200) });
  }
  items.push({ file: f, ext, kind, bytes, sha256, width, height, durationS, hasAudio, vcodec });
}

// Collapse exact duplicates by sha256 — keep the first, mark the rest.
const seen = new Map();
for (const it of items) {
  if (seen.has(it.sha256)) it.dupOf = seen.get(it.sha256);
  else { seen.set(it.sha256, it.file); it.dupOf = null; }
}

writeFileSync(join("c:/Anish/arul-import", "inventory.json"), JSON.stringify(items, null, 2));

// ---- terse summary ----
const uniq = items.filter((i) => !i.dupOf);
const dupes = items.filter((i) => i.dupOf);
const imgs = uniq.filter((i) => i.kind === "image");
const vids = uniq.filter((i) => i.kind === "video");
const dimHist = (arr) => {
  const m = {};
  for (const i of arr) { const k = `${i.width}x${i.height}`; m[k] = (m[k] || 0) + 1; }
  return Object.entries(m).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}:${n}`).join("  ");
};
console.log(`total files       : ${items.length}`);
console.log(`exact dupes        : ${dupes.length} (collapsed)`);
console.log(`unique items       : ${uniq.length}  (image=${imgs.length} video=${vids.length})`);
console.log(`\nIMAGE dims         : ${dimHist(imgs)}`);
console.log(`VIDEO dims         : ${dimHist(vids)}`);
const withAudio = vids.filter((i) => i.hasAudio).length;
const codecHist = {};
for (const v of vids) codecHist[v.vcodec] = (codecHist[v.vcodec] || 0) + 1;
console.log(`video codecs       : ${Object.entries(codecHist).map(([k, n]) => `${k}:${n}`).join("  ")}`);
console.log(`videos with audio  : ${withAudio}/${vids.length}`);
const durs = vids.map((v) => v.durationS).filter((d) => d != null).sort((a, b) => a - b);
if (durs.length) console.log(`video duration s   : min=${durs[0]} med=${durs[Math.floor(durs.length / 2)]} max=${durs[durs.length - 1]}`);
const nonPortraitV = vids.filter((v) => v.width && v.height && v.width >= v.height);
const nonPortraitI = imgs.filter((v) => v.width && v.height && v.width >= v.height);
console.log(`\nlandscape/square videos (need attention): ${nonPortraitV.length}  images: ${nonPortraitI.length}`);
if (errors.length) console.log(`\nERRORS (${errors.length}):`, JSON.stringify(errors, null, 2));
console.log(`\ninventory.json written (${items.length} entries)`);
