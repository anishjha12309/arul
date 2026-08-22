// QC a folder of ready-to-upload live wallpapers — no import-plan needed.
//
// verify.mjs checks files listed in import-plan.json, i.e. the scripted-import path.
// This checks a plain FOLDER, for the hand-off path: files the operator uploads
// through the CMS by hand. It enforces both gates a manual upload must clear:
//
//   docs/media-conventions.md  — h264 / yuv420p / 1024x1824 / no audio / faststart
//                                / <=15MB / <=10s / non-black first frame
//   the CMS's own server gate  — hsr-cms media-verify.ts verifyLiveWallpaper():
//                                stsd fourcc in {avc1, avc3}, width%128==0,
//                                height%32==0, within 1088x1920, <=15MB, <=10s
//
// The CMS gate matters more than it looks: it runs per file on batch create and
// ONE failure rejects the WHOLE batch — no rows inserted and every already-
// uploaded object deleted. Catching it here costs seconds; catching it there
// costs the entire upload.
//
// Usage: node verify-folder.mjs <dir> [<dir>...]
import { readdirSync, statSync, openSync, readSync, closeSync, mkdtempSync } from "fs";
import { execFileSync } from "child_process";
import { join, basename } from "path";
import { tmpdir } from "os";
import { createRequire } from "module";
const require = createRequire("c:/Anish/Unified CMS/");
const sharp = require("sharp");

const DIRS = process.argv.slice(2).filter((a) => !a.startsWith("--"));
if (!DIRS.length) { console.error("usage: verify-folder.mjs <dir> [<dir>...]"); process.exit(2); }
const tmp = mkdtempSync(join(tmpdir(), "qcf-"));

// Authoring ceiling (owner, 2026-08-21), NOT the server's — the Worker still
// accepts up to MAX_BYTES_BY_MIME["video/mp4"] = 50 MB so a user submission from
// a phone is not rejected. This is what OUR pipeline is allowed to produce.
const MAX_BYTES = 15 * 1024 * 1024;
const CMS_CODECS = ["avc1", "avc3"];          // WALLPAPER_VIDEO.allowedCodecs

const ffprobe = (f) => JSON.parse(execFileSync("ffprobe",
  ["-v", "error", "-show_streams", "-show_format", "-of", "json", f],
  { encoding: "utf8", maxBuffer: 64 << 20 }));

/** moov before mdat — progressive playback; also what verify.mjs asserts. */
function faststart(path) {
  const fd = openSync(path, "r"), size = statSync(path).size, buf = Buffer.alloc(16);
  let pos = 0, moov = -1, mdat = -1, ftyp = false;
  try {
    while (pos < size) {
      const n = readSync(fd, buf, 0, 16, pos); if (n < 8) break;
      let bs = buf.readUInt32BE(0); const type = buf.toString("ascii", 4, 8);
      if (bs === 1) bs = Number(buf.readBigUInt64BE(8)); else if (bs === 0) bs = size - pos;
      if (type === "ftyp") ftyp = true;
      if (type === "moov" && moov < 0) moov = pos;
      if (type === "mdat" && mdat < 0) mdat = pos;
      if (moov >= 0 && mdat >= 0) break;
      if (bs <= 0) break; pos += bs;
    }
  } finally { closeSync(fd); }
  return { ok: moov >= 0 && mdat >= 0 && moov < mdat, ftyp };
}
async function frame0Luma(file) {
  const out = join(tmp, "f0.png");
  execFileSync("ffmpeg", ["-y", "-i", file, "-vf", "select=eq(n\\,0)", "-vframes", "1", out],
    { stdio: ["ignore", "ignore", "ignore"] });
  return Math.round((await sharp(out).greyscale().stats()).channels[0].mean);
}

let totalFail = 0;
for (const dir of DIRS) {
  const files = readdirSync(dir).filter((f) => f.toLowerCase().endsWith(".mp4")).sort();
  const fails = [], notes = [];
  for (const f of files) {
    const path = join(dir, f);
    const bytes = statSync(path).size;
    const meta = ffprobe(path);
    const v = (meta.streams || []).find((s) => s.codec_type === "video");
    const hasAudio = (meta.streams || []).some((s) => s.codec_type === "audio");
    const fs2 = faststart(path);
    const errs = [];

    if (v?.codec_name !== "h264") errs.push(`codec=${v?.codec_name} (want h264)`);
    // The CMS reads the stsd sample-entry fourcc, not ffprobe's codec_name.
    if (!CMS_CODECS.includes(v?.codec_tag_string)) errs.push(`fourcc=${v?.codec_tag_string} (CMS wants avc1/avc3)`);
    if (v?.pix_fmt !== "yuv420p") errs.push(`pix_fmt=${v?.pix_fmt} (want yuv420p)`);
    if (v?.width !== 1024 || v?.height !== 1824) errs.push(`dims=${v?.width}x${v?.height} (want 1024x1824)`);
    if (v?.width % 128 !== 0 || v?.height % 32 !== 0) errs.push("alignment fail (w%128/h%32)");
    if (v && (Math.min(v.width, v.height) > 1088 || Math.max(v.width, v.height) > 1920)) errs.push("exceeds 1088x1920 cap");
    if (hasAudio) errs.push("HAS AUDIO stream");
    if (!fs2.ftyp) errs.push("no ftyp box (CMS: not a valid MP4)");
    if (!fs2.ok) errs.push("NOT faststart (moov after mdat)");
    if (bytes > MAX_BYTES) errs.push(`${(bytes / 1048576).toFixed(1)}MB > 15MB`);
    const luma = await frame0Luma(path);
    if (luma < 16) errs.push(`frame0 near-black (luma=${luma})`);

    // Not failures — upscales look soft on a 1080p phone, so this is worth the
    // operator's eye rather than a block. Duration IS a failure: normalize.mjs
    // trims to 10 s, so anything longer skipped the pipeline.
    const dur = Number(meta.format?.duration ?? 0);
    if (dur > 10.5) errs.push(`${dur.toFixed(1)}s > 10s (normalize.mjs trims; this was not)`);
    if (bytes > 10 * 1024 * 1024) notes.push(`${f}: ${(bytes / 1048576).toFixed(1)}MB`);

    if (errs.length) fails.push({ f, errs });
  }
  console.log(`\n${basename(dir)} — ${files.length - fails.length}/${files.length} pass`);
  for (const { f, errs } of fails) console.log(`  FAIL ${f}\n       ${errs.join("; ")}`);
  if (notes.length) { console.log(`  notes (not failures):`); for (const n of notes) console.log(`    ${n}`); }
  totalFail += fails.length;
}
console.log(`\n${totalFail === 0 ? "PASS — every file clears both the media conventions and the CMS gate." : `${totalFail} FAILURE(S) — fix before uploading; one bad file rejects the whole CMS batch.`}`);
process.exitCode = totalFail ? 1 : 0;
