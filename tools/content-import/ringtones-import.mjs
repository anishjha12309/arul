// Ringtone import — stage 2 of 2: the LIVE write.
//
//   R2 PUT (audio) → one Neon txn (rows + content_version bump) → build-catalog
//
// Same contract as import.mjs: R2 first, so a failed insert leaves only benign
// orphans (the hourly canonical sweep collects them), and the DB write is one
// transaction. Records ringtone-import-result.json for rollback.
//
//   node ringtones-import.mjs            # live
//   node ringtones-import.mjs --dry-run  # print what it would do, touch nothing
//
// MUST be run from a directory where `postgres` resolves — the staging ROOT
// (c:/Anish/arul-import) holds the node_modules for this pipeline, so copy this
// file there to run it, exactly as the wallpaper scripts are used.
//
// Objects go up through `wrangler r2 object put --remote`, NOT the S3 API: the
// R2 S3 access keys are not on disk anywhere in this repo, while wrangler is
// already authenticated against the account that owns the bucket. Same bytes,
// same headers, one less credential to keep.
import { readFileSync, writeFileSync, existsSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import postgres from "postgres";

const ROOT = process.env.ROOT || "c:/Anish/arul-import";
const WRANGLER =
  process.env.WRANGLER || "c:/Anish/Arul/workers/node_modules/wrangler/bin/wrangler.js";
const BUCKET = "south-indian-wallpapers";
const CDN = "https://arul-cdn.hsrutility.com";
const API = "https://arul-api.hsrutility.com";
const DRY = process.argv.includes("--dry-run");

// See import.mjs — media keys are content UUIDs and an object at a given key
// never changes, so a year + immutable is correct and keeps R2 Class B
// operations (the one part of R2 that is not free) off the hot path.
const MEDIA_CACHE_CONTROL = "public, max-age=31536000, immutable";

function parseEnv(path) {
  const env = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i < 0) continue;
    let v = t.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))
      v = v.slice(1, -1);
    env[t.slice(0, i).trim()] = v;
  }
  return env;
}
const E = parseEnv("c:/Anish/Arul/workers/.dev.vars");

const plan = JSON.parse(readFileSync(join(ROOT, "ringtone-import-plan.json"), "utf8"));
console.log(`plan: ${plan.length} ringtones${DRY ? "  (DRY RUN)" : ""}`);

// ─── 1. Upload audio to R2 ───────────────────────────────────────────────────
// A checkpoint file makes a re-run after a partial failure cheap: already-PUT
// keys are skipped rather than re-uploaded. It is scoped to the CURRENT plan —
// a stale checkpoint from a previous drop would otherwise mark this drop's
// (different, freshly-minted) keys as done and skip real uploads.
const ckPath = join(ROOT, "ringtone-upload-checkpoint.json");
const planKeys = new Set(plan.map((p) => p.audio_key));
const done = new Set(
  (existsSync(ckPath) ? JSON.parse(readFileSync(ckPath, "utf8")) : []).filter((k) =>
    planKeys.has(k),
  ),
);

const failed = [];
for (const [i, p] of plan.entries()) {
  if (done.has(p.audio_key)) {
    console.log(`  [${i + 1}/${plan.length}] skip (done)  ${p.title}`);
    continue;
  }
  if (DRY) {
    console.log(`  [${i + 1}/${plan.length}] would PUT   ${p.audio_key}  <- ${p.localFile}`);
    continue;
  }
  try {
    // `node <wrangler.js>`, not `npx wrangler`: npx is a .cmd on Windows, which
    // Node will only spawn through a shell, and a shell re-splits every argument
    // on whitespace — source filenames have spaces in them and so does the
    // cache-control value, so all 30 uploads failed with "Unknown arguments".
    // Invoking the JS entrypoint directly keeps the argv array intact.
    execFileSync(
      process.execPath,
      [
        WRANGLER, "r2", "object", "put", `${BUCKET}/${p.audio_key}`,
        "--file", p.localFile,
        "--content-type", p.mime,
        "--cache-control", MEDIA_CACHE_CONTROL,
        "--remote",
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    done.add(p.audio_key);
    writeFileSync(ckPath, JSON.stringify([...done], null, 2));
    console.log(`  [${i + 1}/${plan.length}] ok          ${p.title}`);
  } catch (e) {
    const msg = String(e.stderr || e.stdout || e.message).slice(0, 300);
    failed.push({ key: p.audio_key, error: msg });
    console.error(`  [${i + 1}/${plan.length}] FAILED      ${p.title}\n      ${msg}`);
  }
}

if (failed.length) {
  writeFileSync(
    join(ROOT, "ringtone-import-result.json"),
    JSON.stringify({ stage: "r2-failed", failed }, null, 2),
  );
  console.error(`\nABORTING before the DB write — ${failed.length} upload(s) failed.`);
  process.exit(1);
}
console.log(`R2: ${DRY ? 0 : done.size}/${plan.length} objects present`);

if (DRY) {
  console.log("\nDRY RUN — no DB write, no catalog rebuild.");
  process.exit(0);
}

// ─── 2. One Neon transaction: rows + content_version bump ────────────────────
const sql = postgres(E.DATABASE_URL, { ssl: "require", prepare: false });
let before, after, newVersion;
try {
  before = Number((await sql`SELECT count(*)::int AS n FROM ringtones`)[0].n);

  // Incremental drops are normal, so the table being non-empty is fine — what
  // is NOT fine is re-importing a drop that already landed. Stage 1 dedups on
  // TITLE against the live catalog; this is the last line of defence and checks
  // the key, which is the thing that would actually collide in R2.
  const keys = plan.map((p) => p.audio_key);
  const clash = await sql`SELECT audio_key FROM ringtones WHERE audio_key = ANY(${keys})`;
  if (clash.length) {
    console.error(
      `\nREFUSING: ${clash.length} audio_key(s) in this plan already exist as rows, ` +
        `e.g. ${clash[0].audio_key}. Re-generate the plan (stage 1 mints fresh UUIDs).`,
    );
    process.exit(1);
  }
  await sql.begin(async (tx) => {
    for (const p of plan) {
      await tx`
        INSERT INTO ringtones
          (id, title, category, tags, audio_key, cover_key, mime, duration_ms, bytes, is_published, sort_order)
        VALUES
          (${p.id}, ${p.title}, ${p.category}, ${p.tags}, ${p.audio_key}, ${p.cover_key},
           ${p.mime}, ${p.duration_ms}, ${p.bytes}, true, ${p.sort_order})
      `;
    }
    await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
  });
  after = Number((await sql`SELECT count(*)::int AS n FROM ringtones`)[0].n);
  newVersion = Number((await sql`SELECT content_version AS v FROM app_config WHERE id = 1`)[0].v);
} finally {
  await sql.end();
}
console.log(`DB: ${before} -> ${after} rows; content_version now ${newVersion}`);
writeFileSync(
  join(ROOT, "ringtone-import-result.json"),
  JSON.stringify(
    {
      stage: "db-committed",
      newVersion,
      insertedIds: plan.map((p) => p.id),
      keys: plan.map((p) => p.audio_key),
    },
    null,
    2,
  ),
);

// ─── 3. Rebuild the catalog ──────────────────────────────────────────────────
const rb = await fetch(`${API}/internal/build-catalog`, {
  method: "POST",
  headers: { authorization: `Bearer ${E.CATALOG_BUILD_SECRET}` },
});
console.log(`build-catalog: ${rb.status} ${(await rb.text()).slice(0, 300)}`);

// ─── 4. Verify ───────────────────────────────────────────────────────────────
await new Promise((r) => setTimeout(r, 1500));
try {
  const cat = await (
    await fetch(`${CDN}/catalog/ringtones/all_1.json`, { headers: { "cache-control": "no-cache" } })
  ).json();
  console.log(`catalog ringtones total: ${cat.total} (page 1 items: ${cat.items?.length})`);
  console.log(`  first: ${cat.items?.[0]?.title} [${cat.items?.[0]?.category}]`);
} catch (e) {
  console.error("catalog read failed:", e.message);
}
// GET, never HEAD — HEAD does not populate Cloudflare's cache and reports
// DYNAMIC on a rule that is working fine (docs/known-issues.md).
for (const p of plan.slice(0, 3)) {
  const r = await fetch(`${CDN}/${p.audio_key}`);
  console.log(
    `  ${r.status}  ${r.headers.get("content-type")}  ${r.headers.get("cf-cache-status")}  ${p.title}`,
  );
}
console.log(`\nDONE. ${plan.length} ringtones live, content_version ${newVersion}.`);
