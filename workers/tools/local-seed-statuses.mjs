/**
 * Seeds the Status tab for LOCAL testing: transcode -> LOCAL R2 -> debug-branch rows -> flag on -> local rebuild.
 * The clips are THIRD-PARTY (scraped). They go to local R2 and the debug branch ONLY and must NEVER reach
 * production — the WhatsApp Share-to-Status terms need owned/licensed clips (docs/local-stack.md).
 *
 *   node tools/local-seed-statuses.mjs --count 40      # the full local seed, idempotent (re-run = same ids/keys)
 *   node tools/local-seed-statuses.mjs --dry-run       # 2 clips into a temp dir + planned commands/SQL; writes nothing
 *   node tools/local-seed-statuses.mjs --flag off      # flip feature_flags.status_tab only (on|off), bump, rebuild
 *   node tools/local-seed-statuses.mjs --build-only    # just ask the local Worker to rebuild the catalog
 *
 * Encode = docs/media-conventions.md + the Status clip spec: 1024x1824 H.264 High yuv420p limited range, faststart,
 * ~2 Mbps, <=30 s, AAC-LC 128k stereo at -14 LUFS (two-pass loudnorm + limiter), <=10 MB, non-black JPEG poster.
 */
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import {
  BUCKET,
  CDN_DIR,
  WRANGLER_JS,
  openDebugForWrite,
  persistDir,
  refuse,
  refuseRemoteFlags,
  triggerLocalBuild,
} from "./local-lib.mjs";

refuseRemoteFlags(process.argv.slice(2));
const { values: opt } = parseArgs({
  options: {
    count: { type: "string", default: "40" },
    "dry-run": { type: "boolean", default: false },
    flag: { type: "string" },
    "build-only": { type: "boolean", default: false },
    "no-build": { type: "boolean", default: false },
    "persist-to": { type: "string" },
    source: { type: "string", default: "C:/Anish/wallpaper-fetcher/output/hindu_final" },
  },
});

const LANGS = ["tamil", "telugu", "hindi", "kannada"];
/** Labels every clip carries -> they say nothing about the clip, so the category falls through to the next one. */
const GENERIC_LABELS = new Set(["devotional", "futurecontentsource", "specialday"]);
const LABEL_CATEGORY = { krishnavaani: "krishna", shravan: "shravan", shrikhatushyam: "khatu-shyam" };
const MAX_CATEGORIES = 8;
const MAX_SECONDS = 30;
const MAX_BYTES = 10_000_000;
const W = 1024;
const H = 1824;

if (opt["build-only"]) {
  process.exitCode = (await triggerLocalBuild()) ? 0 : 1;
} else if (opt.flag !== undefined) {
  if (opt.flag !== "on" && opt.flag !== "off") refuse("--flag takes on|off");
  await setFlag(opt.flag === "on");
} else {
  await seed();
}

async function seed() {
  const dryRun = opt["dry-run"];
  const count = dryRun ? Math.min(2, Number(opt.count) || 2) : Number(opt.count);
  if (!Number.isInteger(count) || count < 1) refuse("--count must be a positive integer");
  for (const tool of ["ffmpeg", "ffprobe"]) {
    if (spawnSync(tool, ["-version"]).status !== 0) {
      console.error(`${tool} not on PATH`);
      process.exit(2);
    }
  }

  const picks = selectClips(count);
  // Fail fast on the DB before minutes of encoding; a dry run never connects.
  // Closed again at once: the pooler drops a connection left idle through the encode.
  if (!dryRun) {
    const probeSql = openDebugForWrite();
    const [t] = await probeSql`SELECT to_regclass('public.statuses') IS NOT NULL AS ok`;
    await probeSql.end();
    if (!t.ok)
      refuse("no `statuses` table on the debug branch — apply db/schema/30_statuses.sql there first");
  }

  const persist = dryRun ? null : persistDir(opt["persist-to"]);
  const outDir = dryRun
    ? fs.mkdtempSync(path.join(os.tmpdir(), "arul-status-dryrun-"))
    : path.join(persist, "seed-cache");
  fs.mkdirSync(outDir, { recursive: true });
  console.log(`[seed] ${picks.length} clips -> ${outDir}${dryRun ? " (DRY RUN)" : ""}`);

  const rows = [];
  for (const [i, p] of picks.entries()) {
    const t0 = Date.now();
    const mp4 = path.join(outDir, `${p.id}.mp4`);
    const jpg = path.join(outDir, `${p.id}.jpg`);
    let probe = fs.existsSync(mp4) && fs.existsSync(jpg) ? validate(mp4) : null;
    if (!probe?.ok) {
      const r = transcode(p.target, mp4);
      if (!r.ok) {
        console.warn(`[seed] skip ${path.basename(p.target)}: ${r.reason}`);
        continue;
      }
      probe = validate(mp4);
      if (!probe.ok) {
        console.warn(
          `[seed] skip ${path.basename(p.target)}: off-spec after encode — ${probe.problems.join("; ")}`,
        );
        continue;
      }
      const poster = writePoster(mp4, jpg, probe.durationMs / 1000);
      if (!poster.ok) {
        console.warn(`[seed] skip ${path.basename(p.target)}: ${poster.reason}`);
        continue;
      }
    }
    rows.push({ ...p, ...probe });
    console.log(
      `[seed] ${String(i + 1).padStart(2)}/${picks.length} ${p.category.padEnd(11)} ${probe.summary} (${((Date.now() - t0) / 1000).toFixed(0)} s)`,
    );
  }
  if (rows.length === 0) refuse("no clip survived the encode");

  if (dryRun) {
    printPlan(rows, outDir);
    return;
  }

  for (const r of rows) {
    r2put(persist, r.fullKey, path.join(outDir, `${r.id}.mp4`), "video/mp4");
    r2put(persist, r.thumbKey, path.join(outDir, `${r.id}.jpg`), "image/jpeg");
  }
  console.log(`[seed] ${rows.length * 2} objects in LOCAL R2 (${persist})`);

  const cats = categoryOrder(rows);
  const sql = openDebugForWrite();
  const version = await sql.begin(async (tx) => {
    for (const r of rows) {
      await tx`
        INSERT INTO statuses (id, title, category, full_key, mime, duration_ms, width, height, bytes, is_published)
        VALUES (${r.id}, ${r.title}, ${r.category}, ${r.fullKey}, 'video/mp4', ${r.durationMs}, ${r.width},
                ${r.height}, ${r.bytes}, true)
        ON CONFLICT (id) DO UPDATE SET
          title = excluded.title, category = excluded.category, full_key = excluded.full_key,
          duration_ms = excluded.duration_ms, width = excluded.width, height = excluded.height,
          bytes = excluded.bytes, is_published = true
      `;
    }
    for (const [i, slug] of cats.entries()) {
      await tx`
        INSERT INTO categories (slug, kind, is_published, picker_order, published_at)
        VALUES (${slug}, 'status', true, ${i + 1}, now())
        ON CONFLICT (slug, kind) DO UPDATE SET is_published = true, picker_order = excluded.picker_order
      `;
    }
    return bumpFlag(tx, true);
  });
  await sql.end();
  console.log(
    `[seed] debug branch: ${rows.length} statuses upserted, ${cats.length} status categories (${cats.join(", ")}), status_tab=true, content_version=${version}`,
  );
  if (!opt["no-build"]) process.exitCode = (await triggerLocalBuild()) ? 0 : 1;
}

async function setFlag(on) {
  const sql = openDebugForWrite();
  const version = await sql.begin((tx) => bumpFlag(tx, on));
  await sql.end();
  console.log(`[flag] debug branch: status_tab=${on}, content_version=${version}`);
  process.exitCode = (await triggerLocalBuild()) ? 0 : 1;
}

/** The bump is what makes every app re-fetch its catalogs (?v=), so a flag flip without one is invisible. */
async function bumpFlag(tx, on) {
  const [cfg] = await tx`SELECT jsonb_typeof(feature_flags) AS t FROM app_config WHERE id = 1`;
  if (!cfg) refuse("no app_config row on the debug branch");
  if (cfg.t !== "object")
    refuse(`app_config.feature_flags is a ${cfg.t}, not an object — fix it by hand first`);
  const [row] = await tx`
    UPDATE app_config
    SET feature_flags = feature_flags || jsonb_build_object('status_tab', ${on}::boolean),
        content_version = content_version + 1
    WHERE id = 1
    RETURNING content_version
  `;
  return String(row.content_version);
}

function selectClips(count) {
  const manifest = JSON.parse(fs.readFileSync(path.join(opt.source, "manifest.json"), "utf8"));
  const records = (manifest.statuses ?? [])
    .filter((r) => LANGS.includes(r.language) && r.target && fs.existsSync(r.target))
    .sort((a, b) => a.record_id - b.record_id);

  const specific = new Set();
  for (const r of records) r.category = categoryFor(r);
  for (const r of records) if (!LANGS.includes(r.category)) specific.add(r.category);
  // Few chips: specific labels beyond the cap fold back into their language
  const allowed = new Set([...specific].slice(0, MAX_CATEGORIES - LANGS.length));
  for (const r of records)
    if (!LANGS.includes(r.category) && !allowed.has(r.category)) r.category = r.language;

  // Round-robin languages, and categories inside each language, so a small --count still spans the chips
  const queues = LANGS.map((lang) => {
    const byCat = new Map();
    for (const r of records.filter((x) => x.language === lang)) {
      if (!byCat.has(r.category)) byCat.set(r.category, []);
      byCat.get(r.category).push(r);
    }
    const lanes = [...byCat.values()];
    const out = [];
    while (lanes.some((l) => l.length)) for (const l of lanes) if (l.length) out.push(l.shift());
    return out;
  });
  const picked = [];
  while (picked.length < count && queues.some((q) => q.length)) {
    for (const q of queues) if (q.length && picked.length < count) picked.push(q.shift());
  }
  return picked.map((r) => {
    const id = stableUuid(`arul-local-status:${r.record_id}`);
    return {
      id,
      recordId: r.record_id,
      language: r.language,
      category: r.category,
      target: r.target,
      title: titleFor(path.basename(r.target)),
      fullKey: `statuses/${r.category}/${id}.mp4`,
      thumbKey: `thumbs/statuses/${r.category}/${id}.jpg`,
    };
  });
}

function categoryFor(r) {
  for (const label of r.labels ?? []) {
    const k = String(label)
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "");
    if (!k || GENERIC_LABELS.has(k)) continue;
    return LABEL_CATEGORY[k] ?? k;
  }
  return r.language;
}

function categoryOrder(rows) {
  const seen = [...new Set(rows.map((r) => r.category))];
  return [...LANGS.filter((l) => seen.includes(l)), ...seen.filter((c) => !LANGS.includes(c)).sort()];
}

/** The CMS's titleFor (ui.tsx): stem, separators to spaces, each word capitalised. */
function titleFor(name) {
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
function stableUuid(seed) {
  const h = crypto.createHash("sha1").update(seed).digest();
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString("hex");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}

function run(cmd, args) {
  return spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function transcode(src, out) {
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

function validate(file) {
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
function writePoster(mp4, jpg, seconds) {
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

/** Always --local + --persist-to; the bucket name only selects the miniflare store on disk. */
function r2put(persist, key, file, contentType) {
  const r = spawnSync(
    process.execPath,
    [
      WRANGLER_JS,
      "r2",
      "object",
      "put",
      `${BUCKET}/${key}`,
      "--file",
      file,
      "--content-type",
      contentType,
      "--cache-control",
      "public, max-age=3600",
      "--local",
      "--persist-to",
      persist,
    ],
    { cwd: CDN_DIR, encoding: "utf8", env: { ...process.env, WRANGLER_SEND_METRICS: "false" } },
  );
  if (r.status !== 0) {
    console.error(`[seed] local R2 put failed for ${key}: ${(r.stderr || r.stdout).trim().slice(-400)}`);
    process.exit(1);
  }
}

function lit(v) {
  return typeof v === "number" ? String(v) : `'${String(v).replace(/'/g, "''")}'`;
}

function printPlan(rows, outDir) {
  console.log(`\n[dry-run] encoded files kept in ${outDir}`);
  console.log("[dry-run] local R2 puts (wrangler r2 object put ... --local --persist-to <persist dir>):");
  for (const r of rows) console.log(`  ${BUCKET}/${r.fullKey}\n  ${BUCKET}/${r.thumbKey}`);
  console.log("\n[dry-run] SQL for the debug branch (one transaction):\nBEGIN;");
  for (const r of rows) {
    console.log(
      `INSERT INTO statuses (id, title, category, full_key, mime, duration_ms, width, height, bytes, is_published)\n` +
        `  VALUES (${[r.id, r.title, r.category, r.fullKey, "video/mp4", r.durationMs, r.width, r.height, r.bytes].map(lit).join(", ")}, true)\n` +
        "  ON CONFLICT (id) DO UPDATE SET title = excluded.title, category = excluded.category, full_key = excluded.full_key,\n" +
        "    duration_ms = excluded.duration_ms, width = excluded.width, height = excluded.height, bytes = excluded.bytes, is_published = true;",
    );
  }
  for (const [i, slug] of categoryOrder(rows).entries()) {
    console.log(
      `INSERT INTO categories (slug, kind, is_published, picker_order, published_at) VALUES (${lit(slug)}, 'status', true, ${i + 1}, now())\n` +
        "  ON CONFLICT (slug, kind) DO UPDATE SET is_published = true, picker_order = excluded.picker_order;",
    );
  }
  console.log(
    "UPDATE app_config SET feature_flags = feature_flags || jsonb_build_object('status_tab', true),\n" +
      "  content_version = content_version + 1 WHERE id = 1 RETURNING content_version;\nCOMMIT;",
  );
  console.log("\n[dry-run] then: POST http://127.0.0.1:8787/internal/build-catalog (local Worker, local R2)");
}
