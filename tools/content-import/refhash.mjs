// Stage B-ref — perceptual-hash (dHash) every EXISTING R2 object so new imports can
// be checked against them. static → full_key jpg; live → thumbs/<cat>/<stem>.jpg.
// Writes refhashes.json. Robust to the re-encode gap (dHash ignores exact bytes).
import { writeFileSync } from "fs";
import { createRequire } from "module";
const require = createRequire("c:/Anish/Arul/cms/");
const sharp = require("sharp");

const CDN = "https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev";

function arulThumbKey(fullKey) {
  const m = /^wallpapers\/([^/]+)\/([^/]+)$/.exec(fullKey);
  if (!m) return null;
  const stem = m[2].replace(/\.[^.]+$/, "");
  return `thumbs/${m[1]}/${stem}.jpg`;
}

export async function dhash(buf) {
  const { data } = await sharp(buf).greyscale().resize(9, 8, { fit: "fill" }).raw().toBuffer({ resolveWithObject: true });
  let hash = 0n, bit = 0n;
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      if (data[r * 9 + c] < data[r * 9 + c + 1]) hash |= (1n << bit);
      bit++;
    }
  }
  return hash.toString(16).padStart(16, "0");
}

async function pool(items, n, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); }
  }));
  return out;
}

// 1. read the live catalog
const items = [];
for (let p = 1; p <= 40; p++) {
  const r = await fetch(`${CDN}/catalog/wallpapers/all_${p}.json`, { headers: { "cache-control": "no-cache" } });
  if (!r.ok) break;
  const j = await r.json();
  items.push(...j.items);
  if (!j.has_more) break;
}
console.log(`existing catalog items: ${items.length}`);

// 2. hash each (from its representative jpg)
let ok = 0, fail = 0;
const refs = await pool(items, 10, async (it) => {
  const key = it.type === "live" ? arulThumbKey(it.full_key) : it.full_key;
  try {
    const r = await fetch(`${CDN}/${key}`);
    if (!r.ok) throw new Error(`${r.status}`);
    const buf = Buffer.from(await r.arrayBuffer());
    const dh = await dhash(buf);
    ok++;
    return { id: it.id, type: it.type, category: it.category, full_key: it.full_key, dhash: dh };
  } catch (e) {
    fail++;
    return { id: it.id, type: it.type, category: it.category, full_key: it.full_key, dhash: null, error: String(e.message || e) };
  }
});

writeFileSync("c:/Anish/arul-import/refhashes.json", JSON.stringify(refs.filter(Boolean), null, 2));
console.log(`hashed ${ok}, failed ${fail}. refhashes.json written.`);
