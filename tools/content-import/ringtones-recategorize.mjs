// Ringtone category corrections — move rows between categories, and delete rows.
//
//   node ringtones-recategorize.mjs --dry-run
//   node ringtones-recategorize.mjs
//
// Why this is not just an UPDATE: `audio_key` is CATEGORY-PARTITIONED
// (`ringtones/<category>/<uuid>.mp3`, db/schema/04_ringtones.sql). Changing the
// `category` column alone would leave the object sitting under the old
// category's prefix, so the key would lie about where the track belongs. The
// sweep would not care (it walks the whole `ringtones/` prefix), but every
// future listing would — so a move relocates the OBJECT as well as the row.
//
// Ordering, and why:
//   1. PUT the new key         — object now exists at BOTH keys
//   2. one Neon txn            — rows repointed / deleted, content_version bumped
//   3. rebuild the catalog     — users see the new categories
//   4. DELETE the old keys     — only now, when nothing live points at them
// Uploading first means a failure leaves benign orphans (the hourly canonical
// sweep collects them); deleting last means a row is never pointed at an object
// that has already gone.
//
// MUST be run where `postgres` resolves — copy to the staging ROOT, as with the
// other scripts here.
import { readFileSync, existsSync, writeFileSync } from "fs";
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
const MEDIA_CACHE_CONTROL = "public, max-age=31536000, immutable";

// ─── The corrections ─────────────────────────────────────────────────────────
// `null` = delete the track entirely. Keyed by TITLE because that is what a
// human reviews; ids are looked up.
//
// Round 2, 2026-08-06. The first round classified these tracks from their FILE
// NAMES, which was wrong in five places. They were then checked against the
// generation prompts in `C:\ringtones\ringtone-prompts.md`, which state each
// track's deity and its commissioned lyrics, and the attributions were verified
// against published sources. What that turned up:
//
//   · "Amme Narayana" is the CHOTTANIKKARA BHAGAVATHY chant — the `Narayana` in
//     it addresses the Goddess, not Vishnu. It is an Amman track, not Perumal.
//   · "Veera Anjaneya" and "Jaya Mukhyaprana" are both HANUMAN (Mukhyaprana is
//     his Madhwa name). Neither has anything to do with Ayyappan.
//   · "Vigneshwara Namaha" and "Vinayaga Arul" are GANESHA, who is not Shiva.
//   · "Guru Raghavendra" is a 16th-c. Madhwa SAINT, not a deity at all.
//
// Ringtones therefore carry a sixth category, `others`, for tracks outside the
// five deities. (Wallpapers do not have it, and ringtones have no `temples` —
// the two tabs derive their chips independently, so they may differ.)
const CORRECTIONS = {
  "Amme Narayana": "amman",
  "Veera Anjaneya": "others",
  "Jaya Mukhyaprana": "others",
  "Vigneshwara Namaha": "others",
  "Vinayaga Arul": "others",
  "Guru Raghavendra": "others",
  "Temple Surge": null,
};

/// Where the original bytes for the first drop live. A move re-uploads from the
/// LOCAL master rather than round-tripping the CDN copy — same bytes, no egress,
/// and it fails loudly if the master is missing instead of silently shipping a
/// re-encode.
const MASTERS = process.env.MASTERS || "c:/ringtones/output";
const masterFor = (title) => join(MASTERS, `${title}-30s.mp3`);

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

const r2 = (args) =>
  execFileSync(process.execPath, [WRANGLER, "r2", "object", ...args, "--remote"], {
    stdio: ["ignore", "pipe", "pipe"],
  });

// ─── Resolve the corrections against the live rows ───────────────────────────
const sql = postgres(E.DATABASE_URL, { ssl: "require", prepare: false });
let plan;
try {
  const titles = Object.keys(CORRECTIONS);
  const rows = await sql`SELECT id, title, category, audio_key FROM ringtones WHERE title = ANY(${titles})`;
  const byTitle = new Map(rows.map((r) => [r.title, r]));

  const missing = titles.filter((t) => !byTitle.has(t));
  if (missing.length) {
    console.error(`REFUSING: no row for ${missing.map((m) => `"${m}"`).join(", ")}`);
    process.exit(1);
  }

  plan = titles.map((title) => {
    const row = byTitle.get(title);
    const target = CORRECTIONS[title];
    if (target === null) return { ...row, action: "delete" };
    if (row.category === target) return { ...row, action: "noop" };
    return {
      ...row,
      action: "move",
      newCategory: target,
      newKey: `ringtones/${target}/${row.id}.mp3`,
      master: masterFor(title),
    };
  });
} catch (e) {
  await sql.end();
  throw e;
}

const moves = plan.filter((p) => p.action === "move");
const deletes = plan.filter((p) => p.action === "delete");
const noops = plan.filter((p) => p.action === "noop");

console.log(`${moves.length} move(s), ${deletes.length} delete(s), ${noops.length} already correct${DRY ? "  (DRY RUN)" : ""}\n`);
for (const m of moves) console.log(`  move    ${m.title.padEnd(26)} ${m.category} -> ${m.newCategory}`);
for (const d of deletes) console.log(`  delete  ${d.title.padEnd(26)} ${d.category}  ${d.audio_key}`);
for (const n of noops) console.log(`  ok      ${n.title.padEnd(26)} ${n.category}`);

const noMaster = moves.filter((m) => !existsSync(m.master));
if (noMaster.length) {
  console.error(`\nREFUSING: missing master file(s):\n  ${noMaster.map((m) => m.master).join("\n  ")}`);
  await sql.end();
  process.exit(1);
}

if (DRY) {
  console.log("\nDRY RUN — nothing written.");
  await sql.end();
  process.exit(0);
}

// ─── 1. PUT the new keys ─────────────────────────────────────────────────────
console.log("\nuploading relocated objects...");
for (const m of moves) {
  r2(["put", `${BUCKET}/${m.newKey}`, "--file", m.master, "--content-type", "audio/mpeg", "--cache-control", MEDIA_CACHE_CONTROL]);
  console.log(`  ok  ${m.newKey}`);
}

// ─── 2. One Neon transaction ─────────────────────────────────────────────────
let before, after, newVersion;
try {
  before = Number((await sql`SELECT count(*)::int AS n FROM ringtones`)[0].n);
  await sql.begin(async (tx) => {
    for (const m of moves) {
      await tx`UPDATE ringtones SET category = ${m.newCategory}, audio_key = ${m.newKey} WHERE id = ${m.id}`;
    }
    for (const d of deletes) {
      await tx`DELETE FROM ringtones WHERE id = ${d.id}`;
    }
    await tx`UPDATE app_config SET content_version = content_version + 1 WHERE id = 1`;
  });
  after = Number((await sql`SELECT count(*)::int AS n FROM ringtones`)[0].n);
  newVersion = Number((await sql`SELECT content_version AS v FROM app_config WHERE id = 1`)[0].v);
  const stragglers = await sql`SELECT count(*)::int AS n FROM ringtones WHERE category = 'temples'`;
  console.log(`DB: ${before} -> ${after} rows; content_version ${newVersion}; rows left on 'temples': ${stragglers[0].n}`);
} finally {
  await sql.end();
}

writeFileSync(
  join(ROOT, "ringtone-recategorize-result.json"),
  JSON.stringify({ newVersion, moves, deletes }, null, 2),
);

// ─── 3. Rebuild ──────────────────────────────────────────────────────────────
const rb = await fetch(`${API}/internal/build-catalog`, {
  method: "POST",
  headers: { authorization: `Bearer ${E.CATALOG_BUILD_SECRET}` },
});
console.log(`build-catalog: ${rb.status} ${(await rb.text()).slice(0, 300)}`);

// ─── 4. Delete the superseded objects ────────────────────────────────────────
// Last, so no live row ever pointed at a key that had already gone.
console.log("\ndeleting superseded objects...");
for (const m of moves) {
  r2(["delete", `${BUCKET}/${m.audio_key}`]);
  console.log(`  gone  ${m.audio_key}`);
}
for (const d of deletes) {
  r2(["delete", `${BUCKET}/${d.audio_key}`]);
  console.log(`  gone  ${d.audio_key}`);
}

// ─── Verify ──────────────────────────────────────────────────────────────────
await new Promise((r) => setTimeout(r, 1500));
for (const m of moves.slice(0, 3)) {
  const res = await fetch(`${CDN}/${m.newKey}`);
  console.log(`  ${res.status}  ${res.headers.get("content-type")}  ${m.title}`);
}
console.log(`\nDONE. content_version ${newVersion}.`);
