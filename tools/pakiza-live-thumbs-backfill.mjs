// Pakiza live-wallpaper thumbnail backfill — RE-RUNNABLE.
//
// Pakiza's bucket historically stored only the MP4 for live wallpapers
// (wallpapers/full/<stem>.mp4, no poster), so the unified CMS showed a ▶
// placeholder. This script fills the gap: for every video missing a thumb it
// extracts the first frame (via the CDN — faststart means only a few KB are
// fetched) and uploads thumbs/full/<stem>.jpg.
//
// SAFETY: thumbs/ is a TOP-LEVEL prefix, deliberately OUTSIDE the prefixes
// Pakiza's orphan-sweep cron touches (wallpapers/, ringtones/). No Pakiza
// app/worker code is involved — this is purely additive bucket data that the
// unified CMS (registry pakizaThumbKey) renders. Re-run any time: existing
// thumbs are skipped, so videos added later (e.g. via submission approval,
// which has no browser-capture step) get covered too.
//
// Prereqs: node 20+, ffmpeg on PATH. Creds read at runtime from the Pakiza
// worker's .dev.vars (READ-ONLY — nothing in the reference folder is written).
import { readFileSync, writeFileSync, mkdtempSync, statSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";
import { tmpdir } from "os";
import { createRequire } from "module";

const require = createRequire("c:/Anish/Arul/cms/"); // borrow cms deps
const { AwsClient } = require("aws4fetch");

const DEV_VARS = "c:/Anish/Pakiza/workers/.dev.vars";
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

const E = parseEnv(DEV_VARS);
const endpoint = E.R2_ENDPOINT.replace(/\/$/, "");
const bucket = E.R2_BUCKET;
const cdn = (E.R2_CDN_BASE_URL || "https://cdn.hsrutility.com").replace(/\/$/, "");
const aws = new AwsClient({
  accessKeyId: E.R2_ACCESS_KEY_ID,
  secretAccessKey: E.R2_SECRET_ACCESS_KEY,
  region: "auto",
  service: "s3",
});

/** List every key under a prefix (paginated ListObjectsV2). */
async function listKeys(prefix) {
  const keys = [];
  let token = null;
  do {
    const qs = new URLSearchParams({ "list-type": "2", prefix, "max-keys": "1000" });
    if (token) qs.set("continuation-token", token);
    const res = await aws.fetch(`${endpoint}/${bucket}?${qs}`, { method: "GET" });
    if (!res.ok) throw new Error(`list ${prefix} failed: ${res.status} ${await res.text()}`);
    const xml = await res.text();
    for (const m of xml.matchAll(/<Key>([^<]+)<\/Key>/g)) keys.push(m[1]);
    const t = /<NextContinuationToken>([^<]+)<\/NextContinuationToken>/.exec(xml);
    token = /<IsTruncated>true<\/IsTruncated>/.test(xml) && t ? t[1] : null;
  } while (token);
  return keys;
}

const videos = (await listKeys("wallpapers/full/")).filter((k) => k.endsWith(".mp4"));
const existing = new Set(await listKeys("thumbs/full/"));
const stem = (k) => k.slice("wallpapers/full/".length).replace(/\.mp4$/, "");
const missing = videos.filter((k) => !existing.has(`thumbs/full/${stem(k)}.jpg`));
console.log(`videos: ${videos.length} · thumbs present: ${existing.size} · missing: ${missing.length}`);

const tmp = mkdtempSync(join(tmpdir(), "pkzthumb-"));
let up = 0;
const failed = [];
for (let i = 0; i < missing.length; i++) {
  const key = missing[i];
  const out = join(tmp, "f.jpg");
  const thumbKey = `thumbs/full/${stem(key)}.jpg`;
  try {
    // First frame from the CDN URL, scaled to 540w (CMS preview size class).
    execFileSync(
      "ffmpeg",
      ["-y", "-i", `${cdn}/${key}`, "-frames:v", "1", "-vf", "scale=540:-2", "-q:v", "4", out],
      { stdio: ["ignore", "ignore", "pipe"], timeout: 60000 },
    );
    if (statSync(out).size < 1000) throw new Error("suspiciously small frame");
    const body = readFileSync(out);
    let ok = false;
    for (let a = 1; a <= 3 && !ok; a++) {
      const r = await aws
        .fetch(`${endpoint}/${bucket}/${thumbKey}`, {
          method: "PUT",
          body,
          headers: { "content-type": "image/jpeg" },
        })
        .catch(() => null);
      if (r && r.ok) ok = true;
      else if (a < 3) await new Promise((s) => setTimeout(s, 400 * a));
    }
    if (!ok) throw new Error("PUT failed after 3 attempts");
    up++;
  } catch (e) {
    failed.push({ key, error: String(e.message || e).slice(0, 200) });
  }
  if ((i + 1) % 20 === 0 || i === missing.length - 1)
    console.log(`  ${i + 1}/${missing.length} processed (${up} uploaded, ${failed.length} failed)`);
}

console.log(`\nuploaded ${up}/${missing.length} thumbs`);
if (failed.length) {
  const report = join(tmp, "failed.json");
  writeFileSync(report, JSON.stringify(failed, null, 2));
  console.log(`FAILED ${failed.length} — details: ${report}`);
  for (const f of failed.slice(0, 5)) console.log(`  ${f.key}: ${f.error}`);
  process.exit(1);
}
console.log("done — re-run any time; existing thumbs are skipped.");
