// Stage C — normalize to Arul media rules. Images→1080x1920 JPG; videos→1024x1824
// H.264/faststart/no-audio + a first-frame thumbnail. Writes normalized-manifest.json.
// Per-item try/catch so one bad file never aborts the batch. Terse progress to stdout.
//
// Fidelity settings are tuned for what actually arrives: generator drops are
// routinely 720x1280, so most clips are UPSCALED 1.42x to reach 1024 wide.
// Upscaling cannot add detail, and the old CRF 24 — tuned for native-resolution
// masters — put compression mush on top of an already-soft frame. Measured on a
// real drop (2026-08-21), lanczos + a light unsharp at CRF 21 lifted frame
// sharpness 35 -> 57 at the same output resolution. Native/downscaled sources
// skip the heavy sharpening (it only adds halos there) and take CRF 20.
// Geometry is unchanged and is a COVER fit — scale(increase) + crop NEVER
// stretches; on a 9:16 source it trims 2px of width and no height at all.
import { readFileSync, writeFileSync, mkdirSync, statSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { createRequire } from "module";

// sharp is not a dependency of this repo — borrow it from the hsr-cms checkout
// (the in-repo cms/ folder this used to point at was removed on 2026-07-20).
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

/** Hard ceiling for a live clip (owner, 2026-08-21). Was 50 MB. */
const MAX_VID_BYTES = 15 * 1048576;
/** Live clips are cut to this. The shipped library sits at 4-10 s. */
const MAX_VID_SECONDS = 10;

/**
 * Filter chain + encoder args for one clip.
 *
 * `out_range=tv` + `format=yuv420p` are load-bearing: without them ffmpeg emits
 * full-range `yuvj420p` from a full-range source, which verify.mjs rejects — the
 * whole reason fix.mjs exists. They are set here so a batch never needs repair.
 * `aq-mode=3` spends bits on flat gradients, which is where smoke and sky band.
 */
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
      // Same fidelity reasoning as the video path: a 736px-wide source has to be
      // upscaled 1.47x to reach 1080, so it gets lanczos3 plus a sharpen pass and
      // a higher JPEG quality. A source already at or above 1080 is downscaling,
      // where sharpening only adds halos.
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
      // Auto-trim (owner, 2026-08-21): a drop arrived with 44.8s and 30.5s clips
      // against a library that sits at 4-10s. The cut is blind — it takes the
      // FIRST window, so it can land mid-motion and will not respect a loop
      // point — hence the `trimmed` flag: review those before publishing.
      const srcSeconds = it.durationS ?? 0;
      const trimmed = srcSeconds > MAX_VID_SECONDS;
      const trimArgs = trimmed ? ["-t", String(MAX_VID_SECONDS)] : [];
      execFileSync("ffmpeg", [
        "-y", "-i", src, ...trimArgs, ...videoArgs(it.width), outFile,
      ], { stdio: ["ignore", "ignore", "ignore"], maxBuffer: 64 * 1048576 });
      let bytes = statSync(outFile).size;

      // Best detail-per-byte under a HARD ceiling: quality-first CRF, and only a
      // clip that overshoots pays a bitrate cap, sized from its own duration.
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
      // first-frame thumbnail from the normalized clip (frame matches what ships)
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
