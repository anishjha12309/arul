// Stage C — normalize to Arul media rules. Images→1080x1920 JPG; videos→1024x1824
// H.264/faststart/no-audio + a first-frame thumbnail. Writes normalized-manifest.json.
// Per-item try/catch so one bad file never aborts the batch. Terse progress to stdout.
import { readFileSync, writeFileSync, mkdirSync, statSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { createRequire } from "module";

const require = createRequire("c:/Anish/Arul/cms/"); // borrow cms's sharp
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
      await sharp(src)
        .resize(TARGET_IMG.w, TARGET_IMG.h, { fit: "cover", position: "centre" })
        .jpeg({ quality: 86, mozjpeg: true })
        .toFile(outFile);
      const bytes = statSync(outFile).size;
      if (bytes > 10 * 1048576) flags.push("oversize");
      out.push({ src: it.file, kind: "image", base, ext: "jpg", out: `${base}.jpg`, thumb: null, bytes, srcDims: `${it.width}x${it.height}`, flags });
      console.log(`[${done}/${work.length}] img ${it.file} -> ${base}.jpg (${mb(bytes)}MB) ${flags.join(",")}`);
    } else {
      const outFile = join(OUT, `${base}.mp4`);
      execFileSync("ffmpeg", [
        "-y", "-i", src,
        "-vf", "scale=1024:1824:force_original_aspect_ratio=increase,crop=1024:1824,setsar=1",
        "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-crf", "24", "-preset", "medium", "-movflags", "+faststart", "-an",
        outFile,
      ], { stdio: ["ignore", "ignore", "ignore"], maxBuffer: 64 * 1048576 });
      const bytes = statSync(outFile).size;
      if (bytes > 50 * 1048576) flags.push("oversize");
      if ((it.width ?? 9999) < 1000) flags.push("upscaled");
      if ((it.durationS ?? 0) > 20) flags.push("long");
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
