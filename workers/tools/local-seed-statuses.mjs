/**
 * Seeds the Status tab for LOCAL testing: transcode -> LOCAL R2 -> debug-branch rows -> flag on -> local rebuild.
 * The clips are THIRD-PARTY (scraped). This seed writes local R2 and the debug branch ONLY; a prod upload is
 * the owner's call through tools/status-import.mjs (docs/status-clips.md).
 *
 *   node tools/local-seed-statuses.mjs --count 40      # the full local seed, idempotent (re-run = same ids/keys)
 *   node tools/local-seed-statuses.mjs --dry-run       # 2 clips into a temp dir + planned commands/SQL; writes nothing
 *   node tools/local-seed-statuses.mjs --flag off      # flip feature_flags.status_tab only (on|off), bump, rebuild
 *   node tools/local-seed-statuses.mjs --build-only    # just ask the local Worker to rebuild the catalog
 */
import { spawnSync } from "node:child_process";
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
import { stableUuid, titleFor, transcode, validate, writePoster } from "./lib/status-media.mjs";

refuseRemoteFlags(process.argv.slice(2));
const { values: opt } = parseArgs({
  options: {
    count: { type: "string", default: "40" },
    "dry-run": { type: "boolean", default: false },
    flag: { type: "string" },
    "build-only": { type: "boolean", default: false },
    "no-build": { type: "boolean", default: false },
    "persist-to": { type: "string" },
    source: {
      type: "string",
      default: path.join(os.homedir(), "Anish", "wallpaper-fetcher", "output", "hindu_final"),
    },
  },
});

const LANGS = ["tamil", "telugu", "hindi", "kannada"];
/** Labels every clip carries -> they say nothing about the clip, so the category falls through to the next one. */
const GENERIC_LABELS = new Set(["devotional", "futurecontentsource", "specialday"]);
const LABEL_CATEGORY = { krishnavaani: "krishna", shravan: "shravan", shrikhatushyam: "khatu-shyam" };
const MAX_CATEGORIES = 8;

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
