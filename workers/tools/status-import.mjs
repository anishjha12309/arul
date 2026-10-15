/**
 * Bulk Status import into PRODUCTION: encode -> R2 (clip + poster) -> ONE Neon txn (rows, categories, one
 * content_version bump) -> build-catalog. One category per language. Never touches feature_flags.
 *
 *   node tools/status-import.mjs --langs tamil,telugu            # encode + QC + plan; writes nothing remote
 *   node tools/status-import.mjs --langs tamil,telugu --write    # the live import
 *   node tools/status-import.mjs --langs tamil,telugu --rebuild-only   # rows committed, rebuild failed
 *   node tools/status-import.mjs --manifest <dir>/manifest.json --seed arul-status-hd --width 768 \
 *     --langs tamil,telugu,kannada,malayalam --draft --write    # hidden drafts: no bump, no rebuild
 *
 * --local swaps every target: local R2, the debug branch, the local Worker (docs/local-stack.md).
 * R2 goes first, as in ringtones-import -> a failed DB write leaves only orphans the canonical sweep collects.
 */
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { parseArgs } from "node:util";
import {
  CDN_DIR,
  openDebugForWrite,
  persistDir,
  refuseRemoteFlags,
  triggerLocalBuild,
  WRANGLER_JS,
} from "./local-lib.mjs";
import { openBranch } from "./lib/neon-branch.mjs";
import { encodeAll, stableUuid, titleFor, W } from "./lib/status-media.mjs";

if (process.argv.includes("--local")) refuseRemoteFlags(process.argv.slice(2));
const { values: opt } = parseArgs({
  strict: true,
  options: {
    langs: { type: "string" },
    write: { type: "boolean", default: false },
    source: {
      type: "string",
      default: path.join(os.homedir(), "Anish", "wallpaper-fetcher", "output", "hindu_final"),
    },
    manifest: { type: "string" },
    seed: { type: "string", default: "arul-status" },
    width: { type: "string", default: String(W) },
    only: { type: "string" },
    draft: { type: "boolean", default: false },
    local: { type: "boolean", default: false },
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
const LOCAL_CACHE_CONTROL = "public, max-age=3600";
/** Crafto's slot names -> the shapes the app draws (db/schema/39_status_photo_slot.sql). */
const SLOT_SHAPES = {
  CIRCLE: "circle",
  "BLURRED CIRCLE": "soft_circle",
  "PIN SHAPE BLURRED": "pin",
  "BLURRED SQUARE SHAPE FINAL": "soft_square",
  SQUARE: "square",
};

const langs = (opt.langs ?? "")
  .split(",")
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);
if (langs.length === 0 || langs.some((l) => !/^[a-z]+$/.test(l))) usage("--langs takes e.g. tamil,telugu");
const jobs = Number(opt.jobs);
if (!Number.isInteger(jobs) || jobs < 1) usage("--jobs must be a positive integer");
const width = Number(opt.width);
if (!Number.isInteger(width) || width % 128 !== 0 || width < 128 || width > 1088)
  usage("--width must be a multiple of 128, ≤1088 (the video rule)");
if (!/^[a-z0-9-]+$/.test(opt.seed)) usage("--seed takes e.g. arul-status-hd");
const only = opt.only === undefined ? null : new Set(opt.only.split(",").map((s) => s.trim().toLowerCase()));
if (only && [...only].some((k) => !/^[a-z]+:\d+$/.test(k)))
  usage("--only takes e.g. tamil:10630050,telugu:10721133");
if (opt.draft && opt["rebuild-only"])
  usage("--draft never rebuilds; publish the drafts, then --rebuild-only");
// local-cdn proxies a key it lacks to the production CDN, whose 404 is edge-cached for a year -> a rehearsal
// sharing a key with the live import could poison it the day its local copy is gone
if (opt.local && opt.write && !opt.seed.includes("local"))
  usage(
    "--local --write needs its own --seed (e.g. arul-status-hd-local): local keys must never be live keys",
  );
if (!fs.existsSync(WRANGLER)) usage("run from workers/ so node_modules/wrangler resolves");

fs.mkdirSync(opt.out, { recursive: true });
const persist = opt.local ? persistDir() : null;
const suffix = opt.local ? "-local" : "";
const picks = selectClips();

// A committed import whose rebuild failed -> a re-run would refuse on the clash check, so rebuild alone.
if (opt["rebuild-only"]) {
  const db = openDb();
  try {
    const [cfg] = await db`SELECT content_version FROM app_config WHERE id = 1`;
    process.exitCode = (await rebuildAndVerify(picks, String(cfg.content_version))) ? 0 : 1;
  } finally {
    await db.end();
  }
  process.exit();
}
console.log(
  `[import] ${picks.length} source clips (${langs.join(", ")}) -> ${opt.out}` +
    `${opt.local ? "  (LOCAL)" : ""}${opt.draft ? "  (DRAFT)" : ""}${opt.write ? "" : "  (DRY RUN)"}`,
);

const rows = [];
const skipped = [];
let finished = 0;
const files = picks.map((p) => ({
  mp4: path.join(opt.out, `${p.id}.mp4`),
  jpg: path.join(opt.out, `${p.id}.jpg`),
}));
const results = await encodeAll(
  picks.map((p, i) => ({ src: p.target, ...files[i], opts: { width } })),
  jobs,
  (i, r) => {
    finished++;
    if (!r.ok) return skip(picks[i], r.reason);
    console.log(
      `[import] ${String(finished).padStart(3)}/${picks.length} ${picks[i].category.padEnd(9)} ${r.probe.summary} (${r.seconds.toFixed(0)} s)`,
    );
  },
);
// Task order, not finish order -> the commit and the catalog check read the set as selectClips sorted it
for (const [i, r] of results.entries()) if (r.ok) rows.push({ ...picks[i], ...r.probe, ...files[i] });
console.log(`[import] ${rows.length} clips pass QC, ${skipped.length} skipped`);
for (const s of skipped) console.log(`  skip ${s.file}: ${s.reason}`);
if (rows.length === 0) fail("no clip survived the encode");

const sql = openDb();
try {
  const keys = rows.map((r) => r.fullKey);
  const ids = rows.map((r) => r.id);
  const clash = await sql`
    SELECT id, full_key FROM statuses WHERE full_key = ANY(${keys}) OR id = ANY(${ids}::uuid[])
  `;
  if (clash.length)
    fail(
      `${clash.length} row(s) already hold an id or key of this set, e.g. ${clash[0].id} ${clash[0].full_key} — ` +
        (opt.draft
          ? "this draft set is already in; nothing to do"
          : "this set is in; --rebuild-only if its rebuild failed"),
    );

  const byCat = Object.fromEntries(langs.map((l) => [l, rows.filter((r) => r.category === l).length]));
  const slots = rows.filter((r) => r.photoSlot).length;
  // Without the column the commit fails AFTER every R2 put -> refuse here, in the plan run too
  if (slots > 0) {
    try {
      await sql`SELECT photo_slot FROM statuses LIMIT 0`;
    } catch (e) {
      fail(`apply db/schema/39_status_photo_slot.sql first (${e.message})`);
    }
  }
  console.log(
    `[import] plan: ${rows.length} rows ${JSON.stringify(byCat)}, ${slots} with a photo slot, ${rows.length * 2} R2 objects`,
  );
  if (!opt.write) {
    console.log("[import] DRY RUN — no R2 put, no DB write, no rebuild. Re-run with --write.");
    process.exitCode = 0;
  } else {
    await upload(rows);
    const version = await commit(sql, rows);
    const resultFile = path.join(opt.out, `status-import-result${suffix}.json`);
    if (opt.draft) {
      console.log(
        `[import] DB: ${rows.length} DRAFT statuses inserted; content_version untouched, no rebuild`,
      );
      fs.writeFileSync(resultFile, JSON.stringify({ stage: "db-committed-draft", ids, keys }, null, 2));
      process.exitCode = 0;
    } else {
      console.log(`[import] DB: ${rows.length} statuses inserted, content_version now ${version}`);
      fs.writeFileSync(resultFile, JSON.stringify({ stage: "db-committed", version, ids, keys }, null, 2));
      process.exitCode = (await rebuildAndVerify(rows, version)) ? 0 : 1;
    }
  }
} finally {
  await sql.end();
}

/** Production by default; --local opens the debug branch only, through local-lib's fail-closed guard. */
function openDb() {
  return opt.local ? openDebugForWrite() : openBranch();
}

function selectClips() {
  const records = opt.manifest ? manifestRecords() : sourceRecords();
  const wanted = records.filter((r) => !only || only.has(`${r.language}:${r.record_id}`));
  const present = wanted.filter((r) => fs.existsSync(r.target));
  const gone = wanted.filter((r) => !present.includes(r));
  if (gone.length)
    console.warn(`[import] ${gone.length} record(s) dropped, file not found, e.g. ${gone[0].target}`);
  const picks = present
    .sort((a, b) => a.record_id - b.record_id)
    .map((r) => {
      const id = stableUuid(`${opt.seed}:${r.record_id}`);
      return {
        id,
        recordId: r.record_id,
        category: r.language,
        target: r.target,
        title: r.title,
        photoSlot: r.photoSlot,
        fullKey: `statuses/${r.language}/${id}.mp4`,
        thumbKey: `thumbs/statuses/${r.language}/${id}.jpg`,
      };
    });
  const missing = [...(only ?? [])].filter((k) => !picks.some((p) => `${p.category}:${p.recordId}` === k));
  if (missing.length) usage(`--only names clips outside the manifest or --langs: ${missing.join(", ")}`);
  return picks;
}

/** The first library's manifest: `statuses[]`, each with an absolute `target`. */
function sourceRecords() {
  const manifest = JSON.parse(fs.readFileSync(path.join(opt.source, "manifest.json"), "utf8"));
  return (manifest.statuses ?? [])
    .filter((r) => langs.includes(r.language) && r.target)
    .map((r) => ({ ...r, title: titleFor(path.basename(r.target)), photoSlot: null }));
}

/**
 * A `clips[]` manifest, each `file` relative to the manifest's folder (~/Anish/crafto-hd-statuses).
 * Titles keep the first library's "<label> <record>" shape, which its file names carried.
 */
function manifestRecords() {
  const file = path.resolve(opt.manifest);
  const dir = path.dirname(file);
  const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  // The row id is seed + record_id with no language -> a repeat anywhere in the manifest shares one row
  const seen = new Set();
  for (const c of manifest.clips ?? []) {
    if (seen.has(c.record_id)) fail(`record_id ${c.record_id} appears twice in ${file}`);
    seen.add(c.record_id);
  }
  return (manifest.clips ?? [])
    .filter((c) => langs.includes(c.language))
    .map((c) => {
      if (!Number.isSafeInteger(c.record_id) || c.record_id < 1) usage(`bad record_id ${c.record_id}`);
      // An empty `file` resolves to the folder itself, which exists -> it would pass the file check
      if (typeof c.file !== "string" || !c.file.trim()) usage(`${c.language}:${c.record_id} has no file`);
      const target = path.resolve(dir, c.file);
      // Outside data -> a `file` that climbs out of the manifest's folder is refused, never followed
      if (path.relative(dir, target).startsWith("..")) usage(`${c.record_id}: file ${c.file} leaves ${dir}`);
      const label = (c.crafto_labels ?? []).find((l) => /^[A-Za-z]+$/.test(l) && l !== "FutureContentSource");
      return {
        language: c.language,
        record_id: c.record_id,
        target,
        title: titleFor(`${label ?? "Devotional"}_${c.record_id}`),
        photoSlot: slotOf(c),
      };
    });
}

/** Left and size are % of the clip's width, top % of its height -> fractions to 4 places; null = no slot. */
function slotOf(c) {
  const s = c.photo_slot;
  if (!s) return null;
  const frac = (pct) => (typeof pct === "number" ? Number((pct / 100).toFixed(4)) : Number.NaN);
  const slot = {
    left: frac(s.left_pct_of_width),
    top: frac(s.top_pct_of_height),
    size: frac(s.size_pct_of_width),
    shape: Object.hasOwn(SLOT_SHAPES, s.shape) ? SLOT_SHAPES[s.shape] : undefined,
  };
  const inFrame = [slot.left, slot.top, slot.size].every((v) => v >= 0 && v <= 1);
  if (!slot.shape || !inFrame)
    usage(`${c.language}:${c.record_id} has an unreadable photo_slot ${JSON.stringify(s).slice(0, 200)}`);
  return slot;
}

async function upload(rows) {
  const ckPath = path.join(opt.out, `status-upload-checkpoint${suffix}.json`);
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
  // One writer on the local store: miniflare keeps it on disk, shared with the running Worker
  const lanes = opt.local ? 1 : jobs;
  console.log(`[import] R2${suffix}: ${todo.length} to put (${done.size} already up), ${lanes} at a time`);
  const failed = [];
  let n = 0;
  const run = promisify(execFile);
  async function worker() {
    for (let t = todo.shift(); t; t = todo.shift()) {
      try {
        // The JS entrypoint, never `npx` through a shell -> a shell re-splits the cache-control value.
        await run(process.execPath, putArgs(t), {
          env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
          maxBuffer: 16 * 1024 * 1024,
          ...(opt.local ? { cwd: CDN_DIR } : {}),
        });
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
  await Promise.all(Array.from({ length: lanes }, worker));
  if (failed.length) fail(`${failed.length} R2 put(s) failed — nothing written to the DB; re-run to resume`);
  console.log(`[import] R2: all ${tasks.length} objects up`);
}

/** --local is the local seed's put (docs/local-stack.md): the bucket name only picks the store on disk. */
function putArgs(t) {
  const common = ["r2", "object", "put", `${BUCKET}/${t.key}`, "--file", t.file, "--content-type", t.type];
  return opt.local
    ? [WRANGLER_JS, ...common, "--cache-control", LOCAL_CACHE_CONTROL, "--local", "--persist-to", persist]
    : [WRANGLER, ...common, "--cache-control", MEDIA_CACHE_CONTROL, "--remote"];
}

async function commit(sql, rows) {
  const published = !opt.draft;
  return sql.begin(async (tx) => {
    for (const r of rows) {
      // Only a slot names the column -> an import without one never needs 39_status_photo_slot.sql
      // tx.json(object), never tx.json(JSON.stringify(…)): that encodes it twice into a jsonb string the
      // CHECK refuses
      if (r.photoSlot) {
        await tx`
          INSERT INTO statuses (id, title, category, full_key, mime, duration_ms, width, height, bytes, is_published,
                                photo_slot)
          VALUES (${r.id}, ${r.title}, ${r.category}, ${r.fullKey}, 'video/mp4', ${r.durationMs}, ${r.width},
                  ${r.height}, ${r.bytes}, ${published}, ${tx.json(r.photoSlot)})
        `;
      } else {
        await tx`
          INSERT INTO statuses (id, title, category, full_key, mime, duration_ms, width, height, bytes, is_published)
          VALUES (${r.id}, ${r.title}, ${r.category}, ${r.fullKey}, 'video/mp4', ${r.durationMs}, ${r.width},
                  ${r.height}, ${r.bytes}, ${published})
        `;
      }
    }
    // A draft chip is staged as the CMS stages one (hidden, unpositioned) -> its Publish category shows it
    if (opt.draft) {
      for (const slug of langs) {
        await tx`
          INSERT INTO categories (slug, kind, is_published, picker_order)
          VALUES (${slug}, 'status', false, 0)
          ON CONFLICT (slug, kind) DO NOTHING
        `;
      }
      return null;
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
  if (opt.local) return localRebuildAndVerify(rows);
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

/** Reads local R2 off disk, never through local-cdn: a miss there is proxied to the production CDN. */
async function localRebuildAndVerify(rows) {
  if (!(await triggerLocalBuild())) return false;
  const run = promisify(execFile);
  const get = (key) =>
    run(
      process.execPath,
      [WRANGLER_JS, "r2", "object", "get", `${BUCKET}/${key}`, "--pipe", "--local", "--persist-to", persist],
      {
        cwd: CDN_DIR,
        env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
        encoding: "buffer",
        maxBuffer: 64 * 1024 * 1024,
      },
    ).then(
      (r) => r.stdout,
      () => null,
    );
  const page = await get("catalog/statuses/all_1.json");
  const listed = new Set((page ? JSON.parse(page.toString("utf8")).items : []).map((i) => i.full_key));
  const missing = rows.filter((r) => !listed.has(r.fullKey));
  console.log(`[import] local catalog: ${listed.size} statuses, ${missing.length} of this import missing`);
  for (const r of missing.slice(0, 5)) console.log(`  missing ${r.fullKey}`);
  let ok = missing.length === 0;
  for (const r of [rows[0], rows[rows.length - 1]]) {
    for (const key of [r.fullKey, r.thumbKey]) {
      const body = await get(key);
      console.log(`  ${body ? `${body.length} B` : "MISSING"} ${key}`);
      ok &&= Boolean(body?.length);
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
