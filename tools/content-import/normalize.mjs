// Stage C -> normalize to Arul media rules: images to 1080x1920 JPG, videos to 1024x1824 H.264/faststart/no-audio.
// Writes normalized-manifest.json plus a first-frame thumbnail per clip.
// Per-item try/catch -> one bad file never aborts the batch.
// Generator drops are routinely 720x1280 -> most clips are UPSCALED 1.42x -> upscaling cannot add detail.
// CRF 24, tuned for native masters, put compression mush on an already-soft frame -> lanczos + unsharp at CRF 21 fixed it.
// Native or downscaled sources skip the heavy sharpening -> it only adds halos there -> they take CRF 20.
// Geometry is a COVER fit -> scale(increase) + crop NEVER stretches -> a 9:16 source loses 2px of width and no height.
import { readFileSync, writeFileSync, mkdirSync, statSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { createRequire } from "module";

// sharp is borrowed from the hsr-cms checkout -> this repo carries no such dependency.
const require = createRequire("c:/Anish/Unified CMS/");
const sharp = require("sharp");

const ROOT = "c:/Anish/arul-import";
const SRC = join(ROOT, "drive");
const OUT = join(ROOT, "normalized");
const THUMB = join(OUT, "thumbs");
mkdirSync(OUT, { recursive: true });
mkdirSync(THUMB, { recursive: true });

const TARGET_IMG = { w: 1080, h: 1920 };
const TARGET_VID = { w: 1024, h: 1824 };
const TARGET_AR = TARGET_IMG.w / TARGET_IMG.h; // 0.5625

/** Hard ceiling for a live clip -> owner's call, well under what the Worker accepts. */
const MAX_VID_BYTES = 15 * 1048576;
/** Live clips are cut to this. The shipped library sits at 4-10 s. */
const MAX_VID_SECONDS = 10;

// Without `out_range=tv` + `format=yuv420p` ffmpeg emits full-range `yuvj420p` -> verify.mjs rejects it.
// That is the whole reason fix.mjs exists -> setting them here means a batch never needs repair.
// `aq-mode=3` spends bits on flat gradients -> that is where smoke and sky band.
function videoArgs(srcWidth, { maxrateK } = {}) {
  const upscaling = (srcWidth ?? 0) < TARGET_VID.w;
  const sharpen = upscaling
    ? "unsharp=5:5:0.6:3:3:0.3"   // restore detail the 1.4x upscale softens
    : "unsharp=3:3:0.3:3:3:0.0";  // near-1:1 resample: a touch only, no halos
  const vf =
    `scale=${TARGET_VID.w}:${TARGET_VID.h}:force_original_aspect_ratio=increase:` +
    `flags=lanczos:out_range=tv,crop=${TARGET_VID.w}:${TARGET_VID.h},` +
    `${sharpen},setsar=1,format=yuv420p`;
  return [
    "-vf", vf,
    "-c:v", "libx264", "-profile:v", "high", "-preset", "slow",
    "-crf", upscaling ? "21" : "20",
    "-x264-params", "aq-mode=3",
    ...(maxrateK ? ["-maxrate", `${maxrateK}k`, "-bufsize", `${maxrateK * 2}k`] : []),
    "-movflags", "+faststart", "-an",
  ];
}

const inv = JSON.parse(readFileSync(join(ROOT, "inventory.json"), "utf8"));
const work = inv.filter((i) => !i.dupOf); // skip exact intra-batch dupes

const stem = (f) => f.replace(/\.[^.]+$/, "").replace(/\s+\(\d+\)$/, "").replace(/[^a-zA-Z0-9_-]/g, "_");
const mb = (b) => Math.round((b / 1048576) * 10) / 10;

const out = [];
let done = 0;
for (const it of work) {
  done++;
  const src = join(SRC, it.file);
  const base = stem(it.file);
  const flags = [];
  try {
    if (it.kind === "image") {
      const ar = it.width && it.height ? it.width / it.height : TARGET_AR;
      if (Math.abs(ar - TARGET_AR) / TARGET_AR > 0.12) flags.push("heavy-crop");
      if ((it.width ?? 9999) < 800 || (it.height ?? 9999) < 1400) flags.push("low-res");
      const outFile = join(OUT, `${base}.jpg`);
      // Same fidelity reasoning as the video path -> an upscaled source gets lanczos3, a sharpen pass and higher quality.
      // A source already at or above 1080 is downscaling -> sharpening there only adds halos.
      const upscalingImg = (it.width ?? 9999) < TARGET_IMG.w;
      let pipe = sharp(src).resize(TARGET_IMG.w, TARGET_IMG.h, {
        fit: "cover",
        position: "centre",
        kernel: "lanczos3",
      });
      if (upscalingImg) pipe = pipe.sharpen({ sigma: 0.8, m1: 0.5, m2: 0.3 });
      await pipe.jpeg({ quality: 92, mozjpeg: true }).toFile(outFile);
      const bytes = statSync(outFile).size;
      if (bytes > 10 * 1048576) flags.push("oversize");
      if (upscalingImg) flags.push("upscaled");
      out.push({ src: it.file, kind: "image", base, ext: "jpg", out: `${base}.jpg`, thumb: null, bytes, srcDims: `${it.width}x${it.height}`, flags });
      console.log(`[${done}/${work.length}] img ${it.file} -> ${base}.jpg (${mb(bytes)}MB) ${flags.join(",")}`);
    } else {
      const outFile = join(OUT, `${base}.mp4`);
      // Auto-trim (owner's call) -> drops have arrived at 30-45 s against a library that sits at 4-10 s.
      // The cut is BLIND -> it takes the first window, can land mid-motion and ignores loop points.
      // Hence the `trimmed` flag -> review every trimmed clip before publishing.
      const srcSeconds = it.durationS ?? 0;
      const trimmed = srcSeconds > MAX_VID_SECONDS;
      const trimArgs = trimmed ? ["-t", String(MAX_VID_SECONDS)] : [];
      execFileSync("ffmpeg", [
        "-y", "-i", src, ...trimArgs, ...videoArgs(it.width), outFile,
      ], { stdio: ["ignore", "ignore", "ignore"], maxBuffer: 64 * 1048576 });
      let bytes = statSync(outFile).size;

      // Best detail-per-byte under a HARD ceiling -> quality-first CRF, and only an overshooting clip pays a bitrate cap.
      if (bytes > MAX_VID_BYTES) {
        const seconds = Math.max(1, trimmed ? MAX_VID_SECONDS : srcSeconds || MAX_VID_SECONDS);
        const maxrateK = Math.floor((MAX_VID_BYTES * 8) / seconds / 1000 * 0.92);
        execFileSync("ffmpeg", [
          "-y", "-i", src, ...trimArgs, ...videoArgs(it.width, { maxrateK }), outFile,
        ], { stdio: ["ignore", "ignore", "ignore"], maxBuffer: 64 * 1048576 });
        bytes = statSync(outFile).size;
        flags.push("bitrate-capped");
      }

      if (trimmed) flags.push(`trimmed:${Math.round(srcSeconds)}s`);
      if (bytes > MAX_VID_BYTES) flags.push("oversize");
      if ((it.width ?? 9999) < TARGET_VID.w) flags.push("upscaled");
      // The thumbnail comes from the NORMALIZED clip -> the frame matches what ships.
      const thumbFile = join(THUMB, `${base}.jpg`);
      execFileSync("ffmpeg", [
        "-y", "-ss", "1", "-i", outFile, "-vframes", "1",
        "-vf", "scale=640:-2", "-q:v", "3", thumbFile,
      ], { stdio: ["ignore", "ignore", "ignore"], maxBuffer: 32 * 1048576 });
      out.push({ src: it.file, kind: "video", base, ext: "mp4", out: `${base}.mp4`, thumb: `thumbs/${base}.jpg`, bytes, srcDims: `${it.width}x${it.height}`, durationS: it.durationS, flags });
      console.log(`[${done}/${work.length}] vid ${it.file} -> ${base}.mp4 (${mb(bytes)}MB) ${flags.join(",")}`);
    }
  } catch (e) {
    out.push({ src: it.file, kind: it.kind, base, error: String(e.message || e).slice(0, 300), flags: ["ERROR"] });
    console.log(`[${done}/${work.length}] ERROR ${it.file}: ${String(e.message || e).slice(0, 120)}`);
  }
}

writeFileSync(join(ROOT, "normalized-manifest.json"), JSON.stringify(out, null, 2));
const errs = out.filter((o) => o.flags?.includes("ERROR"));
const flagged = out.filter((o) => o.flags?.length && !o.flags.includes("ERROR"));
console.log(`\nDONE. ${out.length} processed, ${errs.length} errors, ${flagged.length} flagged.`);
console.log(`errors: ${errs.map((e) => e.src).join(", ") || "none"}`);
