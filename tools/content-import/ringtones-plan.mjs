// Ringtone import, stage 1 of 2 -> build the plan.
//
// Ringtone drops arrive already cut to length and NAMED after the deity -> classification is a lookup, QC is one ffprobe.
// That is why this is one small script and not the wallpaper pipeline's eight stages.
//
//   node ringtones-plan.mjs                        # writes ringtone-import-plan.json
//   SRC=c:/path/to/drop node ringtones-plan.mjs
//   node ringtones-plan.mjs --allow-duplicate-titles
//
// Two source layouts, auto-detected:
//   FOLDERED  <SRC>/<FolderName>/*.mp3   → category from FOLDER_CATEGORY
//   FLAT      <SRC>/*.mp3                → category from CATEGORY_BY_TITLE
//
// Writes <ROOT>/ringtone-import-plan.json.
// No credentials and no writes outside ROOT -> the only network call is a READ of the live catalog, for dedup.
import { readdirSync, statSync, writeFileSync } from "fs";
import { execFileSync } from "child_process";
import { join, basename, extname } from "path";
import { randomUUID } from "crypto";

const SRC = process.env.SRC || "c:/ringtones/output";
const ROOT = process.env.ROOT || "c:/Anish/arul-import";
const CDN = process.env.CDN || "https://arul-cdn.hsrutility.com";
const ALLOW_DUPES = process.argv.includes("--allow-duplicate-titles");

// ─── Classification ──────────────────────────────────────────────────────────
// Category is THE browse axis (CLAUDE.md §5b) and the ringtone medallion picks its motif from it.
// A category outside the supported set renders an arbitrary hashed motif -> a real cost, not a cosmetic one.
// RINGTONE CATEGORIES ARE NOT THE WALLPAPER ONES -> there is no `temples`, and there IS an `others` (owner's call).
// The five deities are perumal · murugan · sivan · amman · ayyappan -> anything belonging to none of them is `others`.
// Each tab derives its chips from its own catalog -> the two tabs legitimately differ.
// Classify from the track's LYRICS, NEVER from its file name -> a name-based pass got five of thirty wrong.
// Generated drops ship auto-titles ("Divine Call", "Devout Offering") -> they say nothing about the deity.

// Drop-folder name -> category. The names come from whoever assembled the drive folder.
// So match loosely, lowercased and punctuation-stripped -> keep every spelling that has arrived, never rename the source.
const FOLDER_CATEGORY = {
  amman: "amman",
  ayyappan: "ayyappan",
  ayyappa: "ayyappan",
  murugan: "murugan",
  muruga: "murugan",
  perumal: "perumal",
  // Venkateswara / Balaji / Govinda are all Vishnu at Tirumala.
  govinda: "perumal",
  balaji: "perumal",
  venkateswara: "perumal",
  sivan: "sivan",
  shivji: "sivan",
  shivan: "sivan",
  shiva: "sivan",
  // Anything outside the five deities -> Hanuman, Ganesha, gurus and saints.
  others: "others",
  hanuman: "others",
  anjaneya: "others",
  ganesha: "others",
  vinayagar: "others",
};

// Classified from the generation prompts' LYRICS and verified against published sources.
// The trailing comment on each line is the SPECIFIC deity -> the category is a coarser bucket laid over it.
// This is the record of truth for these titles -> never re-derive it from the file names.
// Those deities are now a real column and `backfill-deity.sql` is the same mapping in SQL -> keep the two in step.
const CATEGORY_BY_TITLE = {
  // perumal — Vishnu and his avatars
  "Anantha Padmanabha": "perumal", // Vishnu, Thiruvananthapuram
  "Bhadradri Ramayya": "perumal", // Rama, Bhadrachalam
  "Ferocious Roar": "perumal", // Narasimha (Ugram Viram mantra)
  "Jaya Narasimha": "perumal", // Narasimha, Yadadri
  "Namo Venkatesaya": "perumal", // Venkateswara, Tirumala
  "Ranga Ranga": "perumal", // Ranganatha, Srirangam
  "Seven Hills Govinda": "perumal", // Venkateswara, Tirumala
  "Unni Kanna": "perumal", // Krishna, Guruvayur

  // amman — Devi in her forms
  "Amme Narayana": "amman", // Chottanikkara Bhagavathy — NOT Vishnu
  "Attukal Amma": "amman", // Attukal Bhagavathy
  "Guardian Mother": "amman", // Mariamman
  "Jaya Jaya Chamundeshwari": "amman", // Chamundeshwari, Mysore
  "Kanaka Durga": "amman", // Durga, Vijayawada
  "Meenakshi Thaye": "amman", // Meenakshi, Madurai

  // ayyappan
  "Saranam Ayyappa": "ayyappan", // Ayyappan, Sabarimala

  // murugan
  "Divine Call": "murugan", // Shanmukha — confirmed by ear
  "Kukke Subrahmanya": "murugan", // Subrahmanya, Kukke
  "Vetrivel Muruga": "murugan", // Murugan, Palani

  // sivan
  "Cosmic Tandava": "sivan", // Nataraja, Chidambaram
  "Devout Offering": "sivan", // Shiva — confirmed by ear
  "Dharmasthala Manjunatha": "sivan", // Manjunatha (Shiva), Dharmasthala
  "Hara Hara Mahadeva": "sivan", // Mallikarjuna, Srisailam
  "Shiva Shankara": "sivan", // Shiva, Murudeshwara

  // others — belongs to none of the five deities
  "Guru Raghavendra": "others", // a Madhwa SAINT, not a deity
  "Jaya Mukhyaprana": "others", // Hanuman (Madhwa name)
  "Veera Anjaneya": "others", // Hanuman
  "Vigneshwara Namaha": "others", // Ganesha — not Shiva
  "Vinayaga Arul": "others", // Ganesha — not Shiva
};

// Source title -> the title actually shipped. Only for a genuine clash with a row that is ALREADY LIVE.
// Two identically-titled rows are indistinguishable in the list -> renaming the live one breaks a user's existing set.
const TITLE_OVERRIDE = {
  "Muruga Muruga": "Muruga Muruga II", // ≠ the earlier live track of that name
};

// Categories are drawn in this order when interleaving -> largest first, so no long tail of one category at the end.
const INTERLEAVE = ["perumal", "murugan", "sivan", "amman", "others", "ayyappan"];

// docs/media-conventions.md, ringtone audio -> size and codec are HARD, they break playback or the budget.
// Length is only "≤40 s recommended" -> an over-long track warns and ships rather than blocking a drop.
const MAX_BYTES = 15 * 1024 * 1024;
const SOFT_MAX_SECONDS = 40;

const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

// ─── Read the drop ───────────────────────────────────────────────────────────
/** "Amme Narayana-30s.mp3" -> "Amme Narayana" — a cut length must never reach a title the user reads. */
function titleFrom(file) {
  const t = basename(file, extname(file))
    .replace(/-\d+s$/i, "")
    .trim();
  return TITLE_OVERRIDE[t] ?? t;
}

const isAudio = (f) => /\.(mp3|m4a|aac)$/i.test(f);

/** [{path, title, category|null, folder}] across both layouts. */
function collectSources() {
  const entries = readdirSync(SRC);
  const dirs = entries.filter((e) => statSync(join(SRC, e)).isDirectory());
  const out = [];

  for (const d of dirs) {
    const category = FOLDER_CATEGORY[norm(d)];
    for (const f of readdirSync(join(SRC, d)).filter(isAudio)) {
      out.push({ path: join(SRC, d, f), title: titleFrom(f), category, folder: d });
    }
  }
  // The two layouts are ALTERNATIVES, never additive -> a foldered drop usually sits beside an earlier drop's loose files.
  // Reading both would re-offer imported tracks and abort on title collisions -> folders holding audio ARE the drop.
  if (out.length) {
    const loose = entries.filter(isAudio).length;
    if (loose) console.log(`FOLDERED layout — ignoring ${loose} loose file(s) at the top of ${SRC}`);
    return out;
  }

  for (const f of entries.filter(isAudio)) {
    const title = titleFrom(f);
    out.push({ path: join(SRC, f), title, category: CATEGORY_BY_TITLE[title], folder: null });
  }
  return out;
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

// ─── Live catalog, for dedup + the sort_order high-water mark ────────────────
// Read from the CDN, not the DB -> no credentials, and the catalog is what users actually see.
// A drop re-run by mistake is the failure this prevents -> nothing else in the pipeline would notice duplicate rows.
async function readLiveCatalog() {
  const items = [];
  for (let page = 1; page <= 50; page++) {
    const r = await fetch(`${CDN}/catalog/ringtones/all_${page}.json`, {
      headers: { "cache-control": "no-cache" },
    });
    if (!r.ok) break;
    const j = await r.json();
    items.push(...(j.items ?? []));
    if (!j.has_more) break;
  }
  return items;
}

const sources = collectSources();
if (!sources.length) {
  console.error(`No audio under ${SRC}`);
  process.exit(1);
}

const live = await readLiveCatalog();
const liveByTitle = new Map(live.map((i) => [norm(i.title), i.title]));
const maxSortOrder = live.reduce((m, i) => Math.max(m, Number(i.sort_order ?? 0)), 0);
console.log(`live catalog: ${live.length} ringtones, max sort_order ${maxSortOrder}`);

// ─── Classify + QC ───────────────────────────────────────────────────────────
const items = [];
const problems = [];
const warnings = [];
const unclassified = [];
const collisions = [];
const seen = new Map();

for (const src of sources) {
  if (!src.category) {
    unclassified.push(
      src.folder ? `${src.title}  (folder "${src.folder}" unmapped)` : src.title,
    );
    continue;
  }

  const dupLive = liveByTitle.get(norm(src.title));
  if (dupLive) collisions.push(`"${src.title}" is already live as "${dupLive}"`);
  const dupBatch = seen.get(norm(src.title));
  if (dupBatch) collisions.push(`"${src.title}" duplicates "${dupBatch}" in this batch`);
  seen.set(norm(src.title), src.title);

  const bytes = statSync(src.path).size;
  const p = probe(src.path);

  // Anything failing is REPORTED, never silently fixed -> there is no server-side transcoding; the fix belongs upstream.
  if (p.codec !== "mp3") problems.push(`${src.title}: codec=${p.codec}, expected mp3`);
  if (bytes > MAX_BYTES) problems.push(`${src.title}: ${(bytes / 1048576).toFixed(1)}MB > 15MB`);
  if (!p.durationMs) problems.push(`${src.title}: unreadable duration`);
  if (p.durationMs > SOFT_MAX_SECONDS * 1000)
    warnings.push(`${src.title}: ${(p.durationMs / 1000).toFixed(1)}s > ${SOFT_MAX_SECONDS}s (recommended max)`);

  const id = randomUUID();
  items.push({
    id,
    title: src.title,
    category: src.category,
    tags: [],
    audio_key: `ringtones/${src.category}/${id}.mp3`,
    // Row art is a BUNDLED asset resolved from `deity` (deity_art.dart) -> no cover object is uploaded -> this stays null.
    // This plan writes no `deity` either -> the INSERT has no such column -> a drop lands null.
    // A null deity renders the category's default until a follow-up UPDATE sets it (docs/ringtones.md).
    cover_key: null,
    mime: "audio/mpeg",
    duration_ms: p.durationMs,
    bytes,
    localFile: src.path,
    _probe: p,
  });
}

if (unclassified.length) {
  console.error(
    `\nUNCLASSIFIED — add the folder to FOLDER_CATEGORY or the title to ` +
      `CATEGORY_BY_TITLE:\n  ${unclassified.join("\n  ")}`,
  );
  process.exit(1);
}
if (problems.length) {
  console.error(`\nQC FAILURES:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
if (collisions.length && !ALLOW_DUPES) {
  console.error(
    `\nTITLE COLLISIONS:\n  ${collisions.join("\n  ")}\n\n` +
      `Re-running an already-imported drop is the usual cause. If these really are ` +
      `distinct recordings, re-run with --allow-duplicate-titles.`,
  );
  process.exit(1);
}

// ─── Interleave → sort_order ─────────────────────────────────────────────────
// A drop is ONE transaction -> without an explicit sort_order every new row ties and clumps by insertion order.
// Continue from the live high-water mark -> an existing user's first screen does not re-shuffle.
// Round-robin the categories inside the new block -> it alternates deities instead of running one for 18 rows.
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
  it.sort_order = maxSortOrder + i + 1;
});

// ─── Report + write ──────────────────────────────────────────────────────────
const counts = {};
for (const it of ordered) counts[it.category] = (counts[it.category] ?? 0) + 1;

console.log(`\n${ordered.length} tracks to import.\n`);
console.log("category counts:", counts);
if (warnings.length) console.log(`\nWARNINGS (shipping anyway):\n  ${warnings.join("\n  ")}`);
if (collisions.length) console.log(`\nCOLLISIONS ALLOWED:\n  ${collisions.join("\n  ")}`);

console.log("\nappended feed order:");
for (const it of ordered) {
  console.log(
    `  ${String(it.sort_order).padStart(3)}  ${it.category.padEnd(9)} ${it.title.padEnd(30)} ` +
      `${(it.duration_ms / 1000).toFixed(0)}s  ${(it.bytes / 1024).toFixed(0)}KB`,
  );
}

const out = join(ROOT, "ringtone-import-plan.json");
writeFileSync(out, JSON.stringify(ordered, null, 2));
console.log(`\nwrote ${out}`);
