/**
 * Re-encode the LIVE status library at each clip's own shape (docs/status-clips.md): the padded
 * 1024×1824 clips lose their blurred fill bands, the picture inside them becomes the whole clip.
 *
 *   node tools/status-reencode.mjs                 # every published clip: fetch, cut, encode, QC; writes nothing remote
 *   node tools/status-reencode.mjs --limit 3       # the first three only (a rehearsal)
 *   node tools/status-reencode.mjs --write         # R2 (new keys) -> ONE Neon txn (rows + content_version) -> build-catalog
 *
 * Media keys are immutable-cached for a year, so a re-encode is a NEW key (`<uuid>-v2.mp4` + its poster)
 * on the SAME row -> ids, share and download counts and `/s/` links all survive; the old objects become
 * orphans the canonical sweep collects. The audio is copied as is: it was levelled to −14 LUFS once.
 */
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs, promisify } from "node:util";
import { openBranch } from "./lib/neon-branch.mjs";
import { stableUuid, transcode, validate, writePoster } from "./lib/status-media.mjs";

const { values: opt } = parseArgs({
  strict: true,
  options: {
    write: { type: "boolean", default: false },
    limit: { type: "string" },
    out: { type: "string", default: path.join(os.homedir(), "Anish", "arul-import", "statuses-v2") },
    manifest: {
      type: "string",
      default: path.join(
        os.homedir(),
        "Anish",
        "wallpaper-fetcher",
        "output",
        "hindu_final",
        "manifest.json",
      ),
    },
    jobs: { type: "string", default: "6" },
  },
});

const WRANGLER = path.resolve("node_modules/wrangler/bin/wrangler.js");
const BUCKET = "south-indian-wallpapers";
const API = "https://arul-api.hsrutility.com";
const CDN = "https://arul-cdn.hsrutility.com";
const MEDIA_CACHE_CONTROL = "public, max-age=31536000, immutable";
const PADDED = { width: 1024, height: 1824 };

const jobs = Number(opt.jobs);
if (!Number.isInteger(jobs) || jobs < 1) usage("--jobs must be a positive integer");
const limit = opt.limit === undefined ? Infinity : Number(opt.limit);
if (opt.limit !== undefined && (!Number.isInteger(limit) || limit < 1))
  usage("--limit must be a positive integer");
if (!fs.existsSync(WRANGLER)) usage("run from workers/ so node_modules/wrangler resolves");
fs.mkdirSync(opt.out, { recursive: true });

// The import's manifest names every source's resolution -> the band each padded clip carries is exact
const sourceSize = new Map();
if (fs.existsSync(opt.manifest)) {
  for (const r of JSON.parse(fs.readFileSync(opt.manifest, "utf8")).statuses ?? []) {
    const m = /^(\d+)x(\d+)$/.exec(r.resolution ?? "");
    if (m) sourceSize.set(stableUuid(`arul-status:${r.record_id}`), { w: Number(m[1]), h: Number(m[2]) });
  }
}

const done = [];
const skipped = [];
const sql = openBranch();
try {
  const rows = await sql`
    SELECT id, category, full_key, width, height FROM statuses
    WHERE is_published = true ORDER BY created_at ASC, id ASC
  `;
  const todo = rows.filter((r) => r.width === PADDED.width && r.height === PADDED.height).slice(0, limit);
  console.log(
    `[reencode] ${rows.length} published, ${todo.length} padded 1024×1824 to do -> ${opt.out}${opt.write ? "" : "  (DRY RUN)"}`,
  );

  for (const [i, r] of todo.entries()) {
    const t0 = Date.now();
    const stem = `${r.id}-v2`;
    const src = path.join(opt.out, `${r.id}-padded.mp4`);
    const mp4 = path.join(opt.out, `${stem}.mp4`);
    const jpg = path.join(opt.out, `${stem}.jpg`);
    let probe = fs.existsSync(mp4) && fs.existsSync(jpg) ? validate(mp4) : null;
    if (!probe?.ok) {
      if (!(await fetchTo(`${CDN}/${r.full_key}`, src))) {
        skip(r, "CDN fetch failed");
        continue;
      }
      const crop = pictureIn(r.id);
      const enc = transcode(src, mp4, { crop, copyAudio: true });
      if (!enc.ok) {
        skip(r, enc.reason);
        continue;
      }
      probe = validate(mp4);
      if (!probe.ok) {
        skip(r, `off-spec after encode — ${probe.problems.join("; ")}`);
        continue;
      }
      const poster = writePoster(mp4, jpg, probe.durationMs / 1000);
      if (!poster.ok) {
        skip(r, poster.reason);
        continue;
      }
      fs.rmSync(src, { force: true });
    }
    const dir = r.full_key.slice(0, r.full_key.lastIndexOf("/") + 1);
    done.push({
      ...r,
      ...probe,
      mp4,
      jpg,
      newKey: `${dir}${stem}.mp4`,
      thumbKey: `thumbs/${dir}${stem}.jpg`,
    });
    console.log(
      `[reencode] ${String(i + 1).padStart(3)}/${todo.length} ${r.category.padEnd(8)} ${probe.summary} (${((Date.now() - t0) / 1000).toFixed(0)} s)`,
    );
  }
  console.log(`[reencode] ${done.length} clips pass QC, ${skipped.length} skipped`);
  for (const s of skipped) console.log(`  skip ${s.id}: ${s.reason}`);
  if (done.length === 0) fail("no clip survived the encode");

  if (!opt.write) {
    console.log(
      `[reencode] DRY RUN — ${done.length * 2} R2 objects and ${done.length} row updates planned. Re-run with --write.`,
    );
  } else {
    await upload(done);
    const version = await commit(sql, done);
    console.log(`[reencode] DB: ${done.length} statuses re-keyed, content_version now ${version}`);
    fs.writeFileSync(
      path.join(opt.out, "status-reencode-result.json"),
      JSON.stringify({ stage: "db-committed", version, ids: done.map((r) => r.id) }, null, 2),
    );
    process.exitCode = (await rebuildAndVerify(done, version)) ? 0 : 1;
  }
} finally {
  await sql.end();
}

/** The picture inside a padded clip: the source fitted into 1024×1824 by `decrease`, centred. */
function pictureIn(id) {
  const s = sourceSize.get(id) ?? { w: 480, h: 720 }; // every clip in the first library was a 2:3 source
  const scale = Math.min(PADDED.width / s.w, PADDED.height / s.h);
  const w = Math.round((s.w * scale) / 2) * 2;
  const h = Math.round((s.h * scale) / 2) * 2;
  return { x: (PADDED.width - w) / 2, y: (PADDED.height - h) / 2, w, h };
}

async function fetchTo(url, file) {
  const res = await fetch(url);
  if (!res.ok) return false;
  fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  return true;
}

async function upload(rows) {
  const ckPath = path.join(opt.out, "status-reencode-checkpoint.json");
  const planKeys = new Set(rows.flatMap((r) => [r.newKey, r.thumbKey]));
  const done = new Set(
    (fs.existsSync(ckPath) ? JSON.parse(fs.readFileSync(ckPath, "utf8")) : []).filter((k) => planKeys.has(k)),
  );
  const tasks = rows.flatMap((r) => [
    { key: r.newKey, file: r.mp4, type: "video/mp4" },
    { key: r.thumbKey, file: r.jpg, type: "image/jpeg" },
  ]);
  const todo = tasks.filter((t) => !done.has(t.key));
  console.log(`[reencode] R2: ${todo.length} to put (${done.size} already up), ${jobs} at a time`);
  const failed = [];
  const run = promisify(execFile);
  async function worker() {
    for (let t = todo.shift(); t; t = todo.shift()) {
      try {
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
      } catch (e) {
        failed.push(t.key);
        console.error(
          `[reencode] R2 put FAILED ${t.key}: ${String(e.stderr || e.message)
            .trim()
            .slice(-300)}`,
        );
      }
    }
  }
  await Promise.all(Array.from({ length: jobs }, worker));
  if (failed.length) fail(`${failed.length} R2 put(s) failed — nothing written to the DB; re-run to resume`);
  console.log(`[reencode] R2: all ${tasks.length} objects up`);
}

async function commit(sql, rows) {
  return sql.begin(async (tx) => {
    for (const r of rows) {
      await tx`
        UPDATE statuses SET full_key = ${r.newKey}, width = ${r.width}, height = ${r.height},
          bytes = ${r.bytes}, duration_ms = ${r.durationMs}
        WHERE id = ${r.id}
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
  console.log(`[reencode] build-catalog: ${rb.status} ${(await rb.text()).slice(0, 300)}`);
  if (!rb.ok) return false;
  const listed = new Map();
  for (let page = 1, pages = 1; page <= pages; page++) {
    const res = await (await fetch(`${CDN}/catalog/statuses/all_${page}.json?v=${version}`)).json();
    pages = res.total_pages ?? 1;
    for (const item of res.items ?? []) listed.set(item.full_key, item);
  }
  const missing = rows.filter((r) => !listed.has(r.newKey));
  console.log(
    `[reencode] catalog v${version}: ${listed.size} statuses, ${missing.length} of this run missing`,
  );
  for (const r of missing.slice(0, 5)) console.log(`  missing ${r.newKey}`);
  let ok = missing.length === 0;
  for (const r of [rows[0], rows[rows.length - 1]]) {
    const item = listed.get(r.newKey);
    if (item && (item.width !== r.width || item.height !== r.height)) {
      console.log(`  ${r.newKey}: page says ${item.width}×${item.height}, file is ${r.width}×${r.height}`);
      ok = false;
    }
    for (const key of [r.newKey, r.thumbKey]) {
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

function skip(r, reason) {
  skipped.push({ id: r.id, reason });
  console.warn(`[reencode] skip ${r.id}: ${reason}`);
}

function usage(msg) {
  console.error(msg);
  process.exit(2);
}

function fail(msg) {
  console.error(`[reencode] REFUSED: ${msg}`);
  process.exit(1);
}
