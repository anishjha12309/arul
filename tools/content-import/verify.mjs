// QC — verify every imported file against docs/media-conventions.md.
// Static: mjpeg 1080x1920, <=10MB. Live: h264 yuv420p 1024x1824, no-audio,
// faststart (moov<mdat), <=50MB, w%128==0 h%32==0, fits 1088x1920, non-black frame0.
import { readFileSync, statSync, openSync, readSync, closeSync, mkdtempSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { tmpdir } from "os";
import { createRequire } from "module";
const require = createRequire("c:/Anish/Arul/cms/");
const sharp = require("sharp");

const ROOT = "c:/Anish/arul-import";
const plan = JSON.parse(readFileSync(join(ROOT, "import-plan.json"), "utf8"));
const tmp = mkdtempSync(join(tmpdir(), "qc-"));

function ffprobe(file) {
  return JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", file], { encoding: "utf8", maxBuffer: 64 << 20 }));
}
function faststart(path) {
  const fd = openSync(path, "r"), size = statSync(path).size, buf = Buffer.alloc(16);
  let pos = 0, moov = -1, mdat = -1;
  try {
    while (pos < size) {
      const n = readSync(fd, buf, 0, 16, pos); if (n < 8) break;
      let bs = buf.readUInt32BE(0); const type = buf.toString("ascii", 4, 8);
      if (bs === 1) bs = Number(buf.readBigUInt64BE(8)); else if (bs === 0) bs = size - pos;
      if (type === "moov" && moov < 0) moov = pos;
      if (type === "mdat" && mdat < 0) mdat = pos;
      if (moov >= 0 && mdat >= 0) break;
      if (bs <= 0) break; pos += bs;
    }
  } finally { closeSync(fd); }
  return moov >= 0 && mdat >= 0 && moov < mdat;
}
async function frame0Luma(file) {
  const out = join(tmp, "f0.png");
  execFileSync("ffmpeg", ["-y", "-i", file, "-vf", "select=eq(n\\,0)", "-vframes", "1", out], { stdio: ["ignore", "ignore", "ignore"] });
  const s = await sharp(out).greyscale().stats();
  return Math.round(s.channels[0].mean);
}

const fails = [];
let sOk = 0, vOk = 0;
for (const p of plan) {
  const f = join(ROOT, p.localMedia);
  const bytes = statSync(f).size;
  const meta = ffprobe(f);
  const v = (meta.streams || []).find((s) => s.codec_type === "video");
  const hasAudio = (meta.streams || []).some((s) => s.codec_type === "audio");
  const errs = [];
  if (p.type === "static") {
    if (v?.codec_name !== "mjpeg") errs.push(`codec=${v?.codec_name} (want mjpeg)`);
    if (v?.width !== 1080 || v?.height !== 1920) errs.push(`dims=${v?.width}x${v?.height} (want 1080x1920)`);
    if (bytes > 10 << 20) errs.push(`${(bytes / 1048576).toFixed(1)}MB > 10MB`);
    if (!errs.length) sOk++;
  } else {
    if (v?.codec_name !== "h264") errs.push(`codec=${v?.codec_name} (want h264)`);
    if (v?.pix_fmt !== "yuv420p") errs.push(`pix_fmt=${v?.pix_fmt} (want yuv420p)`);
    if (v?.width !== 1024 || v?.height !== 1824) errs.push(`dims=${v?.width}x${v?.height} (want 1024x1824)`);
    if (v?.width % 128 !== 0 || v?.height % 32 !== 0) errs.push(`alignment fail`);
    if (v && (v.width > 1088 || v.height > 1920)) errs.push(`exceeds 1088x1920 cap`);
    if (hasAudio) errs.push(`HAS AUDIO stream`);
    if (!faststart(f)) errs.push(`NOT faststart (moov after mdat)`);
    if (bytes > 50 << 20) errs.push(`${(bytes / 1048576).toFixed(1)}MB > 50MB`);
    const luma = await frame0Luma(f);
    if (luma < 16) errs.push(`frame0 near-black (luma=${luma})`);
    if (!errs.length) vOk++;
  }
  if (errs.length) fails.push({ base: p.base, type: p.type, key: p.full_key, errs });
}

console.log(`STATIC: ${sOk}/${plan.filter((p) => p.type === "static").length} pass`);
console.log(`LIVE:   ${vOk}/${plan.filter((p) => p.type === "live").length} pass`);
console.log(`\nfailures: ${fails.length}`);
for (const f of fails) console.log(`  [${f.type}] ${f.base}\n     ${f.errs.join("; ")}\n     key=${f.key}`);
if (!fails.length) console.log("\n✅ ALL 84 files conform to every media convention.");
