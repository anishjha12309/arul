// Stage F-plan — turn corrections.json + review-data.json into import-plan.json.
// One fresh UUID per item used for BOTH the R2 key stem and the DB id, so the
// video thumb key (thumbs/<cat>/<stem>.jpg) matches full_key's stem exactly.
import { readFileSync, writeFileSync } from "fs";
import { randomUUID } from "crypto";
const ROOT = "c:/Anish/arul-import";
const CATS = new Set(["amman", "ayyappan", "murugan", "perumal", "sivan", "temples"]);
const TITLE = { amman: "Amman", ayyappan: "Lord Ayyappan", murugan: "Lord Murugan", perumal: "Perumal", sivan: "Lord Sivan", temples: "Temple" };

const data = JSON.parse(readFileSync(`${ROOT}/review-data.json`, "utf8"));
const corr = JSON.parse(readFileSync(`${ROOT}/corrections.json`, "utf8"));

// validate coverage
const dataBases = new Set(data.map((d) => d.base));
const corrBases = new Set(Object.keys(corr));
const missing = [...dataBases].filter((b) => !corrBases.has(b));
const extra = [...corrBases].filter((b) => !dataBases.has(b));
if (missing.length || extra.length) {
  console.log(`WARN coverage: ${missing.length} items without a decision, ${extra.length} unknown keys`);
  if (missing.length) console.log("  missing:", missing.slice(0, 20));
  if (extra.length) console.log("  extra:", extra.slice(0, 20));
}

const plan = [];
let skipped = 0, titleReset = 0, badCat = 0;
for (const d of data) {
  const decision = corr[d.base] ?? "SKIP";
  if (decision === "SKIP") { skipped++; continue; }
  if (!CATS.has(decision)) { badCat++; console.log(`  bad category "${decision}" for ${d.base} -> skipping`); continue; }
  const cat = decision;
  const changed = cat !== d.category;
  if (changed) titleReset++;
  const title = changed ? TITLE[cat] : (d.title || TITLE[cat]);
  const stem = randomUUID();
  const ext = d.kind === "image" ? "jpg" : "mp4";
  plan.push({
    id: stem,
    base: d.base,
    kind: d.kind,
    type: d.kind === "image" ? "static" : "live",
    category: cat,
    title,
    full_key: `wallpapers/${cat}/${stem}.${ext}`,
    thumb_key: d.kind === "video" ? `thumbs/${cat}/${stem}.jpg` : null,
    mime: d.kind === "image" ? "image/jpeg" : "video/mp4",
    width: d.kind === "image" ? 1080 : 1024,
    height: d.kind === "image" ? 1920 : 1824,
    duration_ms: d.kind === "video" && d.durationS ? Math.round(d.durationS * 1000) : null,
    bytes: d.bytes,
    localMedia: `normalized/${d.out}`,
    localThumb: d.kind === "video" ? `normalized/${d.thumb}` : null,
  });
}

writeFileSync(`${ROOT}/import-plan.json`, JSON.stringify(plan, null, 2));
const byCat = {}; let vids = 0, imgs = 0;
for (const p of plan) { byCat[p.category] = (byCat[p.category] || 0) + 1; if (p.kind === "video") vids++; else imgs++; }
console.log(`\nIMPORT PLAN: ${plan.length} items  (static=${imgs} live=${vids})`);
console.log(`skipped: ${skipped}, re-categorized (title reset to default): ${titleReset}, bad-cat dropped: ${badCat}`);
console.log(`by category:`, JSON.stringify(byCat));
console.log(`R2 objects to PUT: ${plan.length + vids} (${plan.length} media + ${vids} thumbs)`);
