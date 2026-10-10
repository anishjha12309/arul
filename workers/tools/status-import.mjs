/**
 * Bulk Status import into PRODUCTION: encode -> R2 (clip + poster) -> ONE Neon txn (rows, categories, one
 * content_version bump) -> build-catalog. One category per language. Never touches feature_flags.
 *
 *   node tools/status-import.mjs --langs tamil,telugu            # encode + QC + plan; writes nothing remote
 *   node tools/status-import.mjs --langs tamil,telugu --write    # the live import
 *   node tools/status-import.mjs --langs tamil,telugu --rebuild-only   # rows committed, rebuild failed
 *
 * R2 goes first, as in ringtones-import -> a failed DB write leaves only orphans the canonical sweep collects.
 */
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { parseArgs } from "node:util";
import { openBranch } from "./lib/neon-branch.mjs";
import { stableUuid, titleFor, transcode, validate, writePoster } from "./lib/status-media.mjs";

const { values: opt } = parseArgs({
  strict: true,
  options: {
    langs: { type: "string" },
    write: { type: "boolean", default: false },
    source: {
      type: "string",
      default: path.join(os.homedir(), "Anish", "wallpaper-fetcher", "output", "hindu_final"),
    },
    out: { type: "string", default: path.join(os.homedir(), "Anish", "arul-import", "statuses") },
    jobs: { type: "string", default: "6" },
    "rebuild-only": { type: "boolean", default: false },
  },
});

const WRANGLER = path.resolve("node_modules/wrangler/bin/wrangler.js");
const BUCKET = "south-indian-wallpapers";
const API = "https://arul-api.hsrutility.com";
const CDN = "https://arul-cdn.hsrutility.com";
const MEDIA_CACHE_CONTROL = "public, max-age=31536000, immutable";

const langs = (opt.langs ?? "")
  .split(",")
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);
if (langs.length === 0 || langs.some((l) => !/^[a-z]+$/.test(l))) usage("--langs takes e.g. tamil,telugu");
const jobs = Number(opt.jobs);
if (!Number.isInteger(jobs) || jobs < 1) usage("--jobs must be a positive integer");
if (!fs.existsSync(WRANGLER)) usage("run from workers/ so node_modules/wrangler resolves");

fs.mkdirSync(opt.out, { recursive: true });
const picks = selectClips();

// A committed import whose rebuild failed -> a re-run would refuse on the clash check, so rebuild alone.
if (opt["rebuild-only"]) {
  const db = openBranch();
  try {
    const [cfg] = await db`SELECT content_version FROM app_config WHERE id = 1`;
    process.exitCode = (await rebuildAndVerify(picks, String(cfg.content_version))) ? 0 : 1;
  } finally {
    await db.end();
  }
  process.exit();
}
console.log(
  `[import] ${picks.length} source clips (${langs.join(", ")}) -> ${opt.out}${opt.write ? "" : "  (DRY RUN)"}`,
);

const rows = [];
const skipped = [];
for (const [i, p] of picks.entries()) {
  const t0 = Date.now();
  const mp4 = path.join(opt.out, `${p.id}.mp4`);
  const jpg = path.join(opt.out, `${p.id}.jpg`);
  // Encoded files are cached by id -> a re-run after a failure re-validates instead of re-encoding.
  let probe = fs.existsSync(mp4) && fs.existsSync(jpg) ? validate(mp4) : null;
  if (!probe?.ok) {
    const r = transcode(p.target, mp4);
    if (!r.ok) {
      skip(p, r.reason);
      continue;
    }
    probe = validate(mp4);
    if (!probe.ok) {
      skip(p, `off-spec after encode — ${probe.problems.join("; ")}`);
      continue;
    }
    const poster = writePoster(mp4, jpg, probe.durationMs / 1000);
    if (!poster.ok) {
      skip(p, poster.reason);
      continue;
    }
  }
  rows.push({ ...p, ...probe, mp4, jpg });
  console.log(
    `[import] ${String(i + 1).padStart(3)}/${picks.length} ${p.category.padEnd(8)} ${probe.summary} (${((Date.now() - t0) / 1000).toFixed(0)} s)`,
  );
}
console.log(`[import] ${rows.length} clips pass QC, ${skipped.length} skipped`);
for (const s of skipped) console.log(`  skip ${s.file}: ${s.reason}`);
if (rows.length === 0) fail("no clip survived the encode");

const sql = openBranch();
try {
  const keys = rows.map((r) => r.fullKey);
  const clash = await sql`SELECT full_key FROM statuses WHERE full_key = ANY(${keys})`;
  if (clash.length)
    fail(
      `${clash.length} key(s) already have rows, e.g. ${clash[0].full_key} — this set is in; ` +
        "--rebuild-only if its rebuild failed",
    );

  const byCat = Object.fromEntries(langs.map((l) => [l, rows.filter((r) => r.category === l).length]));
  console.log(`[import] plan: ${rows.length} rows ${JSON.stringify(byCat)}, ${rows.length * 2} R2 objects`);
  if (!opt.write) {
    console.log("[import] DRY RUN — no R2 put, no DB write, no rebuild. Re-run with --write.");
    process.exitCode = 0;
  } else {
    await upload(rows);
    const version = await commit(sql, rows);
    console.log(`[import] DB: ${rows.length} statuses inserted, content_version now ${version}`);
    fs.writeFileSync(
      path.join(opt.out, "status-import-result.json"),
      JSON.stringify({ stage: "db-committed", version, ids: rows.map((r) => r.id), keys }, null, 2),
    );
    process.exitCode = (await rebuildAndVerify(rows, version)) ? 0 : 1;
  }
} finally {
  await sql.end();
}

function selectClips() {
  const manifest = JSON.parse(fs.readFileSync(path.join(opt.source, "manifest.json"), "utf8"));
  return (manifest.statuses ?? [])
    .filter((r) => langs.includes(r.language) && r.target && fs.existsSync(r.target))
    .sort((a, b) => a.record_id - b.record_id)
    .map((r) => {
      const id = stableUuid(`arul-status:${r.record_id}`);
      return {
        id,
        category: r.language,
        target: r.target,
        title: titleFor(path.basename(r.target)),
        fullKey: `statuses/${r.language}/${id}.mp4`,
        thumbKey: `thumbs/statuses/${r.language}/${id}.jpg`,
      };
    });
}

async function upload(rows) {
  const ckPath = path.join(opt.out, "status-upload-checkpoint.json");
  const planKeys = new Set(rows.flatMap((r) => [r.fullKey, r.thumbKey]));
  // Scoped to this plan -> a stale checkpoint must never mark a fresh key done.
  const done = new Set(
    (fs.existsSync(ckPath) ? JSON.parse(fs.readFileSync(ckPath, "utf8")) : []).filter((k) => planKeys.has(k)),
  );
  const tasks = rows.flatMap((r) => [
    { key: r.fullKey, file: r.mp4, type: "video/mp4" },
    { key: r.thumbKey, file: r.jpg, type: "image/jpeg" },
  ]);
  const todo = tasks.filter((t) => !done.has(t.key));
  console.log(`[import] R2: ${todo.length} to put (${done.size} already up), ${jobs} at a time`);
  const failed = [];
  let n = 0;
  const run = promisify(execFile);
  async function worker() {
    for (let t = todo.shift(); t; t = todo.shift()) {
      try {
        // The JS entrypoint, never `npx` through a shell -> a shell re-splits the cache-control value.
        await run(
          process.execPath,
          [
            WRANGLER,
            ..."r2 object put".split(" "),
            `${BUCKET}/${t.key}`,
            "--file",
            t.file,
            "--content-type",
            t.type,
            "--cache-control",
            MEDIA_CACHE_CONTROL,
            "--remote",
          ],
          { env: { ...process.env, WRANGLER_SEND_METRICS: "false" }, maxBuffer: 16 * 1024 * 1024 },
        );
        done.add(t.key);
        fs.writeFileSync(ckPath, JSON.stringify([...done], null, 2));
        if (++n % 20 === 0) console.log(`[import] R2: ${n} put`);
      } catch (e) {
        failed.push(t.key);
        console.error(
          `[import] R2 put FAILED ${t.key}: ${String(e.stderr || e.message)
            .trim()
            .slice(-300)}`,
        );
      }
    }
  }
  await Promise.all(Array.from({ length: jobs }, worker));
  if (failed.length) fail(`${failed.length} R2 put(s) failed — nothing written to the DB; re-run to resume`);
  console.log(`[import] R2: all ${tasks.length} objects up`);
}

async function commit(sql, rows) {
  return sql.begin(async (tx) => {
    for (const r of rows) {
      await tx`
        INSERT INTO statuses (id, title, category, full_key, mime, duration_ms, width, height, bytes, is_published)
        VALUES (${r.id}, ${r.title}, ${r.category}, ${r.fullKey}, 'video/mp4', ${r.durationMs}, ${r.width},
                ${r.height}, ${r.bytes}, true)
      `;
    }
    // New chips go after any status category already positioned; an existing one keeps its place.
    for (const slug of langs) {
      await tx`
        INSERT INTO categories (slug, kind, is_published, published_at, picker_order)
        SELECT ${slug}, 'status', true, now(),
               coalesce((SELECT max(picker_order) FROM categories WHERE kind = 'status'), 0) + 1
        ON CONFLICT (slug, kind) DO NOTHING
      `;
    }
    const [row] = await tx`
      UPDATE app_config SET content_version = content_version + 1 WHERE id = 1 RETURNING content_version
    `;
    return String(row.content_version);
  });
}

async function rebuildAndVerify(rows, version) {
  const secret = devVar("CATALOG_BUILD_SECRET");
  const rb = await fetch(`${API}/internal/build-catalog`, {
    method: "POST",
    headers: { authorization: `Bearer ${secret}` },
  });
  console.log(`[import] build-catalog: ${rb.status} ${(await rb.text()).slice(0, 300)}`);
  if (!rb.ok) return false;
  // The build is synchronous, so the pages for the DB version exist now; version.json may lag its 30 s edge TTL.
  const listed = new Set();
  for (let page = 1, pages = 1; page <= pages; page++) {
    const res = await (await fetch(`${CDN}/catalog/statuses/all_${page}.json?v=${version}`)).json();
    pages = res.total_pages ?? 1;
    for (const item of res.items ?? []) listed.add(item.full_key);
  }
  const missing = rows.filter((r) => !listed.has(r.fullKey));
  console.log(
    `[import] catalog v${version}: ${listed.size} statuses, ${missing.length} of this import missing`,
  );
  for (const r of missing.slice(0, 5)) console.log(`  missing ${r.fullKey}`);
  let ok = missing.length === 0;
  for (const r of [rows[0], rows[rows.length - 1]]) {
    for (const key of [r.fullKey, r.thumbKey]) {
      const res = await fetch(`${CDN}/${key}`);
      await res.body?.cancel();
      console.log(`  ${res.status} ${res.headers.get("content-type")} ${key}`);
      ok &&= res.ok;
    }
  }
  return ok;
}

function devVar(name) {
  for (const raw of fs.readFileSync(".dev.vars", "utf8").split("\n")) {
    const line = raw.trim();
    if (!line.startsWith(`${name}=`)) continue;
    let v = line.slice(name.length + 1).trim();
    if (v.startsWith('"') || v.startsWith("'")) v = v.slice(1, -1);
    return v;
  }
  usage(`no ${name} in workers/.dev.vars`);
}

function skip(p, reason) {
  skipped.push({ file: path.basename(p.target), reason });
  console.warn(`[import] skip ${path.basename(p.target)}: ${reason}`);
}

function usage(msg) {
  console.error(msg);
  process.exit(2);
}

function fail(msg) {
  console.error(`[import] REFUSED: ${msg}`);
  process.exit(1);
}
