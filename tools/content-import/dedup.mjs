// Stage B — compare each normalized item's dHash against existing R2 (refhashes.json)
// and against other batch items. Flags likely duplicates for review (never auto-drops).
import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { createRequire } from "module";
const require = createRequire("c:/Anish/Arul/cms/");
const sharp = require("sharp");

const ROOT = "c:/Anish/arul-import";
const OUT = join(ROOT, "normalized");
const EXIST_T = 10; // hamming <= this vs an existing object => likely already in storage
const BATCH_T = 8;  // hamming <= this vs another batch item => near-dup within this import

async function dhash(path) {
  const { data } = await sharp(path).greyscale().resize(9, 8, { fit: "fill" }).raw().toBuffer({ resolveWithObject: true });
  let hash = 0n, bit = 0n;
  for (let r = 0; r < 8; r++) for (let c = 0; c < 8; c++) { if (data[r * 9 + c] < data[r * 9 + c + 1]) hash |= (1n << bit); bit++; }
  return hash.toString(16).padStart(16, "0");
}
const ham = (a, b) => { let x = BigInt("0x" + a) ^ BigInt("0x" + b), c = 0; while (x) { c += Number(x & 1n); x >>= 1n; } return c; };

const norm = JSON.parse(readFileSync(join(ROOT, "normalized-manifest.json"), "utf8")).filter((o) => !o.flags?.includes("ERROR"));
const refs = JSON.parse(readFileSync(join(ROOT, "refhashes.json"), "utf8")).filter((r) => r.dhash);

const rows = [];
for (const o of norm) {
  const imgPath = o.kind === "video" ? join(OUT, o.thumb) : join(OUT, o.out);
  const dh = await dhash(imgPath);
  let best = { hamming: 999, id: null, category: null };
  for (const r of refs) { const h = ham(dh, r.dhash); if (h < best.hamming) best = { hamming: h, id: r.id, category: r.category, full_key: r.full_key }; }
  rows.push({ ...o, dhash: dh, existMatch: best });
}

// intra-batch near-dup detection
for (let i = 0; i < rows.length; i++) {
  let best = { hamming: 999, src: null };
  for (let j = 0; j < rows.length; j++) {
    if (i === j) continue;
    const h = ham(rows[i].dhash, rows[j].dhash);
    if (h < best.hamming) best = { hamming: h, src: rows[j].src };
  }
  rows[i].batchMatch = best;
  rows[i].existingDup = rows[i].existMatch.hamming <= EXIST_T;
  rows[i].batchNearDup = best.hamming <= BATCH_T;
}

writeFileSync(join(ROOT, "dedup-manifest.json"), JSON.stringify(rows, null, 2));
const ed = rows.filter((r) => r.existingDup);
const bd = rows.filter((r) => r.batchNearDup);
console.log(`items: ${rows.length}`);
console.log(`likely already in R2 (hamming<=${EXIST_T}): ${ed.length}`);
console.log(`near-dup within batch (hamming<=${BATCH_T}): ${bd.length}`);
console.log(`\nexisting-dup detail (src -> matched existing category @ distance):`);
for (const r of ed) console.log(`  ${r.src}  ->  ${r.existMatch.category} @ ${r.existMatch.hamming}`);
