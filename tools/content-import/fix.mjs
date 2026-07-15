// Fix — re-encode live videos whose pix_fmt != yuv420p (full-range yuvj420p) with a
// proper full→limited range conversion, re-verify, and overwrite the SAME R2 keys.
// No DB/catalog change (keys unchanged).
import { readFileSync, statSync, openSync, readSync, closeSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { AwsClient } from "aws4fetch";

const ROOT = "c:/Anish/arul-import";
function parseEnv(path) {
  const env = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim(); if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("="); if (i < 0) continue;
    let v = t.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    env[t.slice(0, i).trim()] = v;
  }
  return env;
}
const E = parseEnv("c:/Anish/Arul/workers/.dev.vars");
const endpoint = E.R2_ENDPOINT.replace(/\/$/, ""), bucket = E.R2_BUCKET;
const aws = new AwsClient({ accessKeyId: E.R2_ACCESS_KEY_ID, secretAccessKey: E.R2_SECRET_ACCESS_KEY, region: "auto", service: "s3" });

const ffprobe = (f) => JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", f], { encoding: "utf8", maxBuffer: 64 << 20 }));
function faststart(path) {
  const fd = openSync(path, "r"), size = statSync(path).size, buf = Buffer.alloc(16);
  let pos = 0, moov = -1, mdat = -1;
  try { while (pos < size) { const n = readSync(fd, buf, 0, 16, pos); if (n < 8) break; let bs = buf.readUInt32BE(0); const type = buf.toString("ascii", 4, 8); if (bs === 1) bs = Number(buf.readBigUInt64BE(8)); else if (bs === 0) bs = size - pos; if (type === "moov" && moov < 0) moov = pos; if (type === "mdat" && mdat < 0) mdat = pos; if (moov >= 0 && mdat >= 0) break; if (bs <= 0) break; pos += bs; } } finally { closeSync(fd); }
  return moov >= 0 && mdat >= 0 && moov < mdat;
}

const plan = JSON.parse(readFileSync(join(ROOT, "import-plan.json"), "utf8"));
const norm = JSON.parse(readFileSync(join(ROOT, "normalized-manifest.json"), "utf8"));
const srcOf = new Map(norm.map((n) => [n.base, n.src]));

// 1. find non-conformant live videos
const bad = [];
for (const p of plan.filter((x) => x.type === "live")) {
  const f = join(ROOT, p.localMedia);
  const v = (ffprobe(f).streams || []).find((s) => s.codec_type === "video");
  if (v?.pix_fmt !== "yuv420p") bad.push(p);
}
console.log(`non-conformant live videos: ${bad.length}`);

// 2. re-encode from source with range conversion
for (const p of bad) {
  const src = join(ROOT, "drive", srcOf.get(p.base));
  const out = join(ROOT, p.localMedia);
  execFileSync("ffmpeg", ["-y", "-i", src,
    "-vf", "scale=1024:1824:force_original_aspect_ratio=increase:out_range=tv,crop=1024:1824,setsar=1,format=yuv420p",
    "-c:v", "libx264", "-profile:v", "high", "-crf", "24", "-preset", "medium",
    "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", out], { stdio: ["ignore", "ignore", "ignore"] });
}
console.log(`re-encoded ${bad.length} videos`);

// 3. re-verify each fixed file
const stillBad = [];
for (const p of bad) {
  const f = join(ROOT, p.localMedia);
  const meta = ffprobe(f);
  const v = (meta.streams || []).find((s) => s.codec_type === "video");
  const audio = (meta.streams || []).some((s) => s.codec_type === "audio");
  const bytes = statSync(f).size;
  const errs = [];
  if (v?.pix_fmt !== "yuv420p") errs.push(`pix_fmt=${v?.pix_fmt}`);
  if (v?.width !== 1024 || v?.height !== 1824) errs.push(`dims=${v?.width}x${v?.height}`);
  if (audio) errs.push("has-audio");
  if (!faststart(f)) errs.push("not-faststart");
  if (bytes > 50 << 20) errs.push("oversize");
  if (errs.length) stillBad.push({ base: p.base, errs });
}
if (stillBad.length) { console.log("RE-VERIFY FAILED, aborting upload:", JSON.stringify(stillBad, null, 2)); process.exit(1); }
console.log(`re-verify: all ${bad.length} now conform`);

// 4. overwrite the same R2 keys
let up = 0; const failed = [];
for (const p of bad) {
  const url = `${endpoint}/${bucket}/${p.full_key}`;
  const body = readFileSync(join(ROOT, p.localMedia));
  let ok = false;
  for (let a = 1; a <= 3 && !ok; a++) {
    try { const r = await aws.fetch(url, { method: "PUT", body, headers: { "content-type": "video/mp4" } }); if (r.ok) ok = true; else if (a === 3) failed.push({ key: p.full_key, status: r.status }); }
    catch (e) { if (a === 3) failed.push({ key: p.full_key, error: String(e.message || e) }); await new Promise((r) => setTimeout(r, 400 * a)); }
  }
  if (ok) up++;
}
console.log(`\nre-uploaded ${up}/${bad.length} to existing keys, ${failed.length} failed`);
if (failed.length) console.log("failed:", JSON.stringify(failed, null, 2));
