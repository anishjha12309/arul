// Stage F — the live import. R2 PUT (media + thumbs) → one Neon txn (84 rows +
// content_version bump) → build-catalog → verify. Records import-result.json for rollback.
import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { AwsClient } from "aws4fetch";
import postgres from "postgres";

const ROOT = "c:/Anish/arul-import";
const CDN = "https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev";
const API = "https://arul-api.twilight-smoke-d495.workers.dev";

// ---- config from workers/.dev.vars ----
function parseEnv(path) {
  const env = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i < 0) continue;
    let v = t.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    env[t.slice(0, i).trim()] = v;
  }
  return env;
}
const E = parseEnv("c:/Anish/Arul/workers/.dev.vars");
const endpoint = E.R2_ENDPOINT.replace(/\/$/, "");
const bucket = E.R2_BUCKET;
const aws = new AwsClient({ accessKeyId: E.R2_ACCESS_KEY_ID, secretAccessKey: E.R2_SECRET_ACCESS_KEY, region: "auto", service: "s3" });

const plan = JSON.parse(readFileSync(join(ROOT, "import-plan.json"), "utf8"));
console.log(`import-plan: ${plan.length} items`);

// ---- 1. upload all R2 objects (media + video thumbs) ----
async function put(key, bytes, ct) {
  const url = `${endpoint}/${bucket}/${key}`;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await aws.fetch(url, { method: "PUT", body: bytes, headers: { "content-type": ct } });
      if (res.ok) return true;
      if (attempt === 3) throw new Error(`${res.status} ${await res.text().catch(() => "")}`);
    } catch (e) { if (attempt === 3) throw e; }
    await new Promise((r) => setTimeout(r, 400 * attempt));
  }
}
const jobs = [];
for (const p of plan) {
  jobs.push({ key: p.full_key, file: join(ROOT, p.localMedia), ct: p.mime });
  if (p.thumb_key) jobs.push({ key: p.thumb_key, file: join(ROOT, p.localThumb), ct: "image/jpeg" });
}
console.log(`uploading ${jobs.length} objects to R2...`);
let up = 0; const failed = [];
async function pool(items, n, fn) {
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) { const k = i++; await fn(items[k]); } }));
}
await pool(jobs, 8, async (j) => {
  try { await put(j.key, readFileSync(j.file), j.ct); up++; if (up % 20 === 0) console.log(`  ${up}/${jobs.length}`); }
  catch (e) { failed.push({ key: j.key, error: String(e.message || e).slice(0, 200) }); }
});
console.log(`R2 upload: ${up} ok, ${failed.length} failed`);
if (failed.length) {
  writeFileSync(join(ROOT, "import-result.json"), JSON.stringify({ stage: "r2-failed", failed }, null, 2));
  console.log("ABORTING before DB write. Failures:", JSON.stringify(failed.slice(0, 10), null, 2));
  process.exit(1);
}

// ---- 2. one Neon transaction: insert rows + bump content_version ----
const sql = postgres(E.DATABASE_URL, { ssl: "require", prepare: false });
let beforeCount, afterCount, newVersion;
try {
  beforeCount = Number((await sql`SELECT count(*)::int AS n FROM wallpapers`)[0].n);
  await sql.begin(async (tx) => {
    for (const p of plan) {
      await tx`
        INSERT INTO wallpapers (id, title, type, category, full_key, mime, is_published, width, height, duration_ms, bytes)
        VALUES (${p.id}, ${p.title}, ${p.type}, ${p.category}, ${p.full_key}, ${p.mime}, true, ${p.width}, ${p.height}, ${p.duration_ms}, ${p.bytes})
      `;
    }
    await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
  });
  afterCount = Number((await sql`SELECT count(*)::int AS n FROM wallpapers`)[0].n);
  newVersion = Number((await sql`SELECT content_version AS v FROM app_config WHERE id = 1`)[0].v);
} finally {
  await sql.end();
}
console.log(`DB: ${beforeCount} -> ${afterCount} rows (+${afterCount - beforeCount}); content_version now ${newVersion}`);
writeFileSync(join(ROOT, "import-result.json"), JSON.stringify({ stage: "db-committed", newVersion, insertedIds: plan.map((p) => p.id), keys: jobs.map((j) => j.key) }, null, 2));

// ---- 3. rebuild catalog ----
const rb = await fetch(`${API}/internal/build-catalog`, { method: "POST", headers: { authorization: `Bearer ${E.CATALOG_BUILD_SECRET}` } });
console.log(`build-catalog: ${rb.status} ${(await rb.text()).slice(0, 200)}`);

// ---- 4. verify: catalog total + a few objects live ----
await new Promise((r) => setTimeout(r, 1500));
let catTotal = null;
try { catTotal = (await (await fetch(`${CDN}/catalog/wallpapers/all_1.json`, { headers: { "cache-control": "no-cache" } })).json()).total; } catch {}
console.log(`catalog total now: ${catTotal}`);
const sample = plan.slice(0, 3).map((p) => p.full_key);
for (const k of sample) { const h = await fetch(`${CDN}/${k}`, { method: "HEAD" }); console.log(`  ${h.status}  ${k}`); }
console.log(`\nDONE. imported ${plan.length}, content_version ${newVersion}, catalog total ${catTotal}.`);
