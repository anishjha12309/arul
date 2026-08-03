/**
 * Backfill missing STATIC wallpaper thumbnails into R2.
 *
 * The app (and now the CMS feed-order panel) derive every grid image as
 * `thumbs/<category>/<stem>.jpg`, but static imports before 2026-08 never
 * generated thumbs — those tiles fall back to the full 1080×1920 original
 * (~700KB into a 110px box). This walks every static row, lists what already
 * exists under `thumbs/`, and generates+uploads only what is missing.
 *
 * Thumb recipe matches the live pipeline (arul-import/clean-batch.mjs):
 * ffmpeg scale=640:-2, q:v 3, JPEG. `thumbs/` is OUTSIDE the canonical sweep
 * prefixes, so an upload here can never be swept and needs no DB row.
 *
 *   cd workers && node tools/backfill-static-thumbs.mjs --dry-run   # report only
 *   cd workers && node tools/backfill-static-thumbs.mjs             # do it
 *
 * Credentials come from workers/.dev.vars (R2_* + DATABASE_URL), same as
 * tools/content-import/import.mjs. Requires ffmpeg on PATH.
 */
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { AwsClient } from "aws4fetch";
import postgres from "postgres";

const DRY = process.argv.includes("--dry-run");
const CDN = "https://arul-cdn.hsrutility.com";

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
const E = parseEnv(new URL("../.dev.vars", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const endpoint = E.R2_ENDPOINT.replace(/\/$/, "");
const bucket = E.R2_BUCKET;
const aws = new AwsClient({
  accessKeyId: E.R2_ACCESS_KEY_ID,
  secretAccessKey: E.R2_SECRET_ACCESS_KEY,
  region: "auto",
  service: "s3",
});

/** "wallpapers/<category>/<stem>.<ext>" → "thumbs/<category>/<stem>.jpg" */
function thumbKey(fullKey) {
  const m = /^wallpapers\/([^/]+)\/([^/]+)$/.exec(fullKey);
  if (!m) return null;
  return `thumbs/${m[1]}/${m[2].replace(/\.[^.]+$/, "")}.jpg`;
}

// ---- 1. every static row (published or not — thumbs are derived, sweep-safe) ----
const sql = postgres(E.DATABASE_URL, { max: 1, prepare: false });
const rows = await sql`SELECT full_key, category, is_published FROM wallpapers WHERE type = 'static'`;
await sql.end();
console.log(`static wallpapers in DB: ${rows.length}`);

// ---- 2. one listing of thumbs/ instead of N existence probes ----
const existing = new Set();
let token;
do {
  const qs = new URLSearchParams({ "list-type": "2", prefix: "thumbs/", "max-keys": "1000" });
  if (token) qs.set("continuation-token", token);
  const res = await aws.fetch(`${endpoint}/${bucket}?${qs}`, { method: "GET" });
  if (!res.ok) throw new Error(`ListObjectsV2 failed: ${res.status}`);
  const xml = await res.text();
  for (const m of xml.matchAll(/<Key>([^<]+)<\/Key>/g)) existing.add(m[1]);
  token = /<NextContinuationToken>([^<]+)<\/NextContinuationToken>/.exec(xml)?.[1];
} while (token);
console.log(`objects under thumbs/: ${existing.size}`);

const missing = rows
  .map((r) => ({ ...r, thumb: thumbKey(r.full_key) }))
  .filter((r) => r.thumb && !existing.has(r.thumb));
console.log(`statics missing a thumb: ${missing.length}`);
if (DRY || missing.length === 0) {
  for (const r of missing.slice(0, 10)) console.log(`  ${r.full_key} -> ${r.thumb}`);
  if (missing.length > 10) console.log(`  … and ${missing.length - 10} more`);
  process.exit(0);
}

// ---- 3. download original → ffmpeg 640-wide jpg → PUT (immutable, like import.mjs) ----
const MEDIA_CACHE_CONTROL = "public, max-age=31536000, immutable";
const work = mkdtempSync(join(tmpdir(), "arul-thumbs-"));
let ok = 0;
const failed = [];
async function one(r) {
  try {
    const src = await fetch(`${CDN}/${r.full_key}`);
    if (!src.ok) throw new Error(`GET original ${src.status}`);
    const inFile = join(work, r.thumb.split("/").pop() + ".src.jpg");
    const outFile = join(work, r.thumb.split("/").pop());
    writeFileSync(inFile, Buffer.from(await src.arrayBuffer()));
    execFileSync("ffmpeg", ["-y", "-i", inFile, "-vf", "scale=640:-2", "-q:v", "3", outFile], { stdio: "pipe" });
    const bytes = readFileSync(outFile);
    for (let attempt = 1; ; attempt++) {
      const res = await aws.fetch(`${endpoint}/${bucket}/${r.thumb}`, {
        method: "PUT",
        body: bytes,
        headers: { "content-type": "image/jpeg", "cache-control": MEDIA_CACHE_CONTROL },
      });
      if (res.ok) break;
      if (attempt === 3) throw new Error(`PUT ${res.status}`);
      await new Promise((res2) => setTimeout(res2, 400 * attempt));
    }
    ok++;
    if (ok % 25 === 0) console.log(`  ${ok}/${missing.length}`);
  } catch (e) {
    failed.push({ key: r.full_key, err: String(e) });
  }
}
// bounded fan-out, mirroring import.mjs's pool discipline
const queue = missing.slice();
await Promise.all(
  Array.from({ length: 4 }, async () => {
    while (queue.length) await one(queue.shift());
  }),
);
rmSync(work, { recursive: true, force: true });

console.log(`done: ${ok} uploaded, ${failed.length} failed`);
for (const f of failed) console.log(`  FAILED ${f.key}: ${f.err}`);
process.exit(failed.length ? 1 : 0);
