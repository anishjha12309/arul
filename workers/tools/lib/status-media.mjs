/** The Status clip encode + QC (spec: docs/status-clips.md), shared by the local seed and the prod import. */
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";

export const MAX_SECONDS = 30;
export const MAX_BYTES = 10_000_000;
export const W = 1024;
export const H = 1824;

/** The CMS's titleFor (ui.tsx): stem, separators to spaces, each word capitalised. */
export function titleFor(name) {
  const stem = name.replace(/\.[^.]+$/, "");
  const pretty = stem
    .replace(/[-_]+/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join(" ");
  return pretty || name;
}

/** UUIDv5-shaped id from the source record -> a re-run upserts the same row and overwrites the same keys. */
export function stableUuid(seed) {
  const h = crypto.createHash("sha1").update(seed).digest();
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString("hex");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}

function run(cmd, args) {
  return spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

export function transcode(src, out) {
  const meta = ffprobeJson(src);
  if (!meta) return { ok: false, reason: "ffprobe could not read the source" };
  if (!meta.streams.some((s) => s.codec_type === "audio"))
    return { ok: false, reason: "source has no audio" };
  // Trimmed short of the cap: AAC frame rounding lands a `-t 30` encode at ~30.1 s, which QC refuses
  const seconds = Math.min(MAX_SECONDS - 0.2, Number(meta.format.duration) || MAX_SECONDS);
  const t = seconds.toFixed(3);

  // Pass 1 measures; pass 2 feeds the measurement back with linear=true (the paywall recipe)
  const m = run("ffmpeg", [
    ..."-hide_banner -nostats -t".split(" "),
    t,
    "-i",
    src,
    "-vn",
    "-af",
    "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json",
    "-f",
    "null",
    "-",
  ]);
  const json = m.stderr.match(/\{[^{}]*"input_i"[^{}]*\}/);
  if (!json) return { ok: false, reason: "loudnorm measure pass failed" };
  const ln = JSON.parse(json[0]);
  const af =
    `loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=${ln.input_i}:measured_TP=${ln.input_tp}:` +
    `measured_LRA=${ln.input_lra}:measured_thresh=${ln.input_thresh}:offset=${ln.target_offset}:linear=true,` +
    "aresample=48000,alimiter=limit=0.84:level=false";
  // Blurred fill, never a crop: a 2:3 source keeps its whole frame inside the 9:16 canvas
  const vf =
    `[0:v]split=2[bg][fg];` +
    `[bg]scale=${W}:${H}:force_original_aspect_ratio=increase:flags=bilinear,crop=${W}:${H},gblur=sigma=30,eq=brightness=-0.06[bgb];` +
    `[fg]scale=${W}:${H}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,unsharp=5:5:0.6:3:3:0.3[fgs];` +
    `[bgb][fgs]overlay=(W-w)/2:(H-h)/2,scale=${W}:${H}:out_range=tv,setsar=1,format=yuv420p[v];` +
    `[0:a:0]${af}[a]`;

  for (const [rate, max] of [
    ["2000k", "2400k"],
    ["1500k", "1800k"],
  ]) {
    const e = run("ffmpeg", [
      ..."-y -hide_banner -nostats -loglevel error -t".split(" "),
      t,
      "-i",
      src,
      "-filter_complex",
      vf,
      ..."-map [v] -map [a] -sn -dn -map_metadata -1".split(" "),
      ..."-c:v libx264 -profile:v high -preset medium -g 60 -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709".split(
        " ",
      ),
      "-b:v",
      rate,
      "-maxrate",
      max,
      "-bufsize",
      "4000k",
      ..."-c:a aac -profile:a aac_low -b:a 128k -ar 48000 -ac 2 -movflags +faststart".split(" "),
      out,
    ]);
    if (e.status !== 0) return { ok: false, reason: `ffmpeg encode failed: ${e.stderr.trim().slice(-300)}` };
    if (fs.statSync(out).size <= MAX_BYTES) return { ok: true };
  }
  return { ok: false, reason: `still over ${MAX_BYTES} bytes at 1.5 Mbps` };
}

function ffprobeJson(file) {
  const r = run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", file]);
  if (r.status !== 0) return null;
  return JSON.parse(r.stdout);
}

export function validate(file) {
  const meta = ffprobeJson(file);
  if (!meta) return { ok: false, problems: ["unreadable"] };
  const v = meta.streams.find((s) => s.codec_type === "video");
  const a = meta.streams.find((s) => s.codec_type === "audio");
  const bytes = Number(meta.format.size);
  const durationMs = Math.round(Number(meta.format.duration) * 1000);
  const problems = [];
  if (v?.codec_name !== "h264" || v?.profile !== "High")
    problems.push(`video ${v?.codec_name}/${v?.profile}`);
  if (v?.width !== W || v?.height !== H) problems.push(`dims ${v?.width}x${v?.height}`);
  if (v?.pix_fmt !== "yuv420p" || v?.color_range === "pc")
    problems.push(`pix ${v?.pix_fmt}/${v?.color_range}`);
  if (a?.codec_name !== "aac" || a?.profile !== "LC" || a?.channels !== 2)
    problems.push(`audio ${a?.codec_name}/${a?.profile}/${a?.channels}ch`);
  if (durationMs > MAX_SECONDS * 1000 + 50) problems.push(`duration ${durationMs} ms`);
  if (bytes > MAX_BYTES) problems.push(`bytes ${bytes}`);
  if (!moovFirst(file)) problems.push("not faststart");
  const lufs = measureLufs(file);
  if (lufs === null || Math.abs(lufs + 14) > 1) problems.push(`loudness ${lufs} LUFS`);
  return {
    ok: problems.length === 0,
    problems,
    width: v?.width,
    height: v?.height,
    bytes,
    durationMs,
    summary:
      `${v?.width}x${v?.height} ${v?.codec_name} ${v?.profile} ${v?.pix_fmt}/${v?.color_range} · ` +
      `${a?.codec_name} ${a?.profile} ${a?.channels}ch ${Math.round(Number(a?.bit_rate) / 1000)}k · ` +
      `${(durationMs / 1000).toFixed(1)} s · ${(bytes / 1e6).toFixed(2)} MB · ${lufs} LUFS · faststart`,
  };
}

function measureLufs(file) {
  const r = run("ffmpeg", [
    "-hide_banner",
    "-nostats",
    "-i",
    file,
    "-vn",
    "-af",
    "ebur128",
    "-f",
    "null",
    "-",
  ]);
  const m = r.stderr.match(/Integrated loudness:\s*\n\s*I:\s*(-?[\d.]+) LUFS/);
  return m ? Number(m[1]) : null;
}

/** Top-level atom walk: faststart means `moov` precedes `mdat`. */
function moovFirst(file) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const buf = Buffer.alloc(16);
    let off = 0;
    while (off + 8 <= size) {
      fs.readSync(fd, buf, 0, 16, off);
      let len = buf.readUInt32BE(0);
      const type = buf.toString("latin1", 4, 8);
      if (type === "moov") return true;
      if (type === "mdat") return false;
      if (len === 1) len = Number(buf.readBigUInt64BE(8));
      if (len < 8) return false;
      off += len;
    }
    return false;
  } finally {
    fs.closeSync(fd);
  }
}

/** First frame bright enough to read as a picture (limited-range black is Y=16). */
export function writePoster(mp4, jpg, seconds) {
  for (const t of [1, 2, 3, 5, 8, 0.5, 0]) {
    if (t >= seconds) continue;
    const s = run("ffmpeg", [
      ..."-hide_banner -nostats -ss".split(" "),
      String(t),
      "-i",
      mp4,
      "-frames:v",
      "1",
      "-vf",
      "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
      "-f",
      "null",
      "-",
    ]);
    const yavg = Number(s.stderr.match(/lavfi\.signalstats\.YAVG=([\d.]+)/)?.[1] ?? 0);
    if (yavg < 32) continue;
    const w = run("ffmpeg", [
      ..."-y -hide_banner -loglevel error -ss".split(" "),
      String(t),
      "-i",
      mp4,
      ..."-frames:v 1 -vf scale=640:-2 -q:v 3".split(" "),
      jpg,
    ]);
    if (w.status === 0) return { ok: true };
  }
  return { ok: false, reason: "no non-black poster frame found" };
}
