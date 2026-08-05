// Ringtone import — stage 1 of 2: build the plan.
//
// The wallpaper pipeline (probe → normalize → dedup → classify → review →
// buildplan) exists because images arrive unlabelled, mis-sized and duplicated.
// Ringtone drops are not like that: they arrive already cut to length and
// already NAMED after the deity, so classification is a title map and the QC is
// one ffprobe. Hence one small script instead of eight.
//
//   node ringtones-plan.mjs            # writes ringtone-import-plan.json
//
// Reads   c:/ringtones/output/*.mp3   (override with SRC)
// Writes  <ROOT>/ringtone-import-plan.json
//
// No credentials, no network, no writes outside ROOT — safe to re-run.
import { readdirSync, statSync, writeFileSync } from "fs";
import { execFileSync } from "child_process";
import { join, basename, extname } from "path";
import { randomUUID } from "crypto";

const SRC = process.env.SRC || "c:/ringtones/output";
const ROOT = process.env.ROOT || "c:/Anish/arul-import";

// ─── Classification ──────────────────────────────────────────────────────────
// Category is THE browse axis (CLAUDE.md §5b) and the ringtone medallion picks
// its motif from it (`_motifByCategory` in ringtone_medallion.dart), so a
// category outside the six deliberately-supported ones would render an
// arbitrary hashed motif — a real cost, not a cosmetic one. Ganesha tracks are
// therefore filed under `sivan` (the Shaiva family) rather than opening a
// seventh category; revisit if a Ganesha motif is ever drawn.
const CATEGORY_BY_TITLE = {
  // amman — Devi in her forms
  "Amme Narayana": "amman",
  "Attukal Amma": "amman",
  "Guardian Mother": "amman",
  "Jaya Jaya Chamundeshwari": "amman",
  "Kanaka Durga": "amman",
  "Meenakshi Thaye": "amman",

  // ayyappan
  "Saranam Ayyappa": "ayyappan",

  // murugan — incl. Subrahmanya
  "Kukke Subrahmanya": "murugan",
  "Vetrivel Muruga": "murugan",

  // perumal — Vishnu, his avatars, and the Vaishnava saints/devotees
  "Anantha Padmanabha": "perumal",
  "Bhadradri Ramayya": "perumal",
  "Ferocious Roar": "perumal", // Narasimha
  "Guru Raghavendra": "perumal",
  "Jaya Mukhyaprana": "perumal", // Hanuman (Madhwa)
  "Jaya Narasimha": "perumal",
  "Namo Venkatesaya": "perumal",
  "Ranga Ranga": "perumal", // Ranganatha
  "Seven Hills Govinda": "perumal",
  "Unni Kanna": "perumal", // Guruvayurappan
  "Veera Anjaneya": "perumal", // Hanuman

  // sivan — Shiva, and (see note above) Ganesha
  "Cosmic Tandava": "sivan",
  "Dharmasthala Manjunatha": "sivan",
  "Hara Hara Mahadeva": "sivan",
  "Shiva Shankara": "sivan",
  "Vigneshwara Namaha": "sivan",
  "Vinayaga Arul": "sivan",

  // temples — non-deity-specific devotional pieces
  "Devout Offering": "temples",
  "Divine Call": "temples",
  "Sacred Raga": "temples",
  "Temple Surge": "temples",
};

// The order categories are drawn from when interleaving. Largest first so the
// round-robin never leaves a long tail of one category at the end of the feed.
const INTERLEAVE = ["perumal", "amman", "sivan", "temples", "murugan", "ayyappan"];

// docs/media-conventions.md — ringtone audio.
const MAX_BYTES = 15 * 1024 * 1024;
const MAX_SECONDS = 40;

// ─── Read + probe ────────────────────────────────────────────────────────────
/** "Amme Narayana-30s.mp3" → "Amme Narayana". The cut length is a production
 *  detail; it must never reach a title the user reads. */
function titleFrom(file) {
  return basename(file, extname(file))
    .replace(/-\d+s$/i, "")
    .trim();
}

function probe(path) {
  const out = execFileSync(
    "ffprobe",
    [
      "-v", "error",
      "-select_streams", "a:0",
      "-show_entries", "stream=codec_name,channels,sample_rate",
      "-show_entries", "format=duration,bit_rate",
      "-of", "json",
      path,
    ],
    { encoding: "utf8" },
  );
  const j = JSON.parse(out);
  const s = j.streams?.[0] ?? {};
  return {
    codec: s.codec_name,
    channels: Number(s.channels),
    sampleRate: Number(s.sample_rate),
    durationMs: Math.round(Number(j.format?.duration ?? 0) * 1000),
    bitRate: Number(j.format?.bit_rate ?? 0),
  };
}

const files = readdirSync(SRC)
  .filter((f) => /\.(mp3|m4a|aac)$/i.test(f))
  .sort();
if (!files.length) {
  console.error(`No audio in ${SRC}`);
  process.exit(1);
}

const items = [];
const problems = [];
const unclassified = [];

for (const file of files) {
  const path = join(SRC, file);
  const title = titleFrom(file);
  const category = CATEGORY_BY_TITLE[title];
  if (!category) {
    unclassified.push(title);
    continue;
  }

  const bytes = statSync(path).size;
  const p = probe(path);

  // QC gate. A ringtone has no dimension rules to break, so the whole gate is
  // codec + length + size; anything failing is REPORTED, never silently fixed —
  // this repo does no server-side transcoding and the fix belongs upstream.
  if (p.codec !== "mp3") problems.push(`${title}: codec=${p.codec}, expected mp3`);
  if (bytes > MAX_BYTES) problems.push(`${title}: ${(bytes / 1048576).toFixed(1)}MB > 15MB`);
  if (p.durationMs > MAX_SECONDS * 1000)
    problems.push(`${title}: ${(p.durationMs / 1000).toFixed(1)}s > ${MAX_SECONDS}s`);
  if (!p.durationMs) problems.push(`${title}: unreadable duration`);

  const id = randomUUID();
  items.push({
    id,
    title,
    category,
    tags: [],
    audio_key: `ringtones/${category}/${id}.mp3`,
    cover_key: null, // the app draws its procedural kolam medallion — no cover art exists
    mime: "audio/mpeg",
    duration_ms: p.durationMs,
    bytes,
    localFile: path,
    _probe: p,
  });
}

if (unclassified.length) {
  console.error(`\nUNCLASSIFIED (add to CATEGORY_BY_TITLE):\n  ${unclassified.join("\n  ")}`);
  process.exit(1);
}
if (problems.length) {
  console.error(`\nQC FAILURES:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}

// ─── Interleave → sort_order ─────────────────────────────────────────────────
// The catalog is ordered `sort_order ASC, created_at DESC` and every row here is
// inserted in ONE transaction, so without an explicit sort_order all 30 tie and
// the list would clump by whatever order they were written. Round-robin across
// categories so the unfiltered list alternates deities the way the feed does.
const byCategory = new Map(INTERLEAVE.map((c) => [c, []]));
for (const it of items) byCategory.get(it.category).push(it);
for (const list of byCategory.values()) list.sort((a, b) => a.title.localeCompare(b.title));

const ordered = [];
for (let round = 0; ordered.length < items.length; round++) {
  for (const c of INTERLEAVE) {
    const next = byCategory.get(c)[round];
    if (next) ordered.push(next);
  }
}
ordered.forEach((it, i) => {
  it.sort_order = i + 1;
});

// ─── Report + write ──────────────────────────────────────────────────────────
const counts = {};
for (const it of ordered) counts[it.category] = (counts[it.category] ?? 0) + 1;

console.log(`\n${ordered.length} tracks, all QC-clean.\n`);
console.log("category counts:", counts);
console.log("\nfeed order (unfiltered list, top first):");
for (const it of ordered) {
  console.log(
    `  ${String(it.sort_order).padStart(2)}  ${it.category.padEnd(9)} ${it.title.padEnd(26)} ` +
      `${(it.duration_ms / 1000).toFixed(0)}s  ${(it.bytes / 1024).toFixed(0)}KB`,
  );
}

const out = join(ROOT, "ringtone-import-plan.json");
writeFileSync(out, JSON.stringify(ordered, null, 2));
console.log(`\nwrote ${out}`);
