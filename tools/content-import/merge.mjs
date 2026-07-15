// Stage D-merge — combine dedup-manifest.json + classifications.json into
// review-data.json (what buildreview.mjs consumes). Classifier output is a map
// { base: {category, confidence, reason, title} }.
import { readFileSync, writeFileSync } from "fs";
const ROOT = "c:/Anish/arul-import";
const CATS = new Set(["amman", "ayyappan", "murugan", "perumal", "sivan", "temples"]);
const TITLE = { amman: "Amman", ayyappan: "Lord Ayyappan", murugan: "Lord Murugan", perumal: "Perumal", sivan: "Lord Sivan", temples: "Temple" };

const dedup = JSON.parse(readFileSync(`${ROOT}/dedup-manifest.json`, "utf8"));
const cls = JSON.parse(readFileSync(`${ROOT}/classifications.json`, "utf8"));

let missing = 0, badCat = 0;
const data = dedup.map((d) => {
  const c = cls[d.base] || {};
  let category = (c.category || "").toLowerCase().trim();
  if (!CATS.has(category)) {
    // fall back to the matched existing category if it's a likely dup, else 'temples' + low conf
    category = CATS.has(d.existMatch?.category) && d.existingDup ? d.existMatch.category : "temples";
    badCat++;
  }
  if (!cls[d.base]) missing++;
  return {
    base: d.base, src: d.src, kind: d.kind, out: d.out, thumb: d.thumb,
    bytes: d.bytes, srcDims: d.srcDims, durationS: d.durationS, flags: d.flags || [],
    existingDup: !!d.existingDup, existMatch: d.existMatch, batchNearDup: !!d.batchNearDup,
    category, confidence: (c.confidence || (cls[d.base] ? "med" : "low")).toLowerCase(),
    reason: c.reason || "", title: c.title || TITLE[category] || "Wallpaper",
  };
});

// sort: dups first, then low-confidence, then by category — so the review surfaces decisions
const order = { high: 2, med: 1, low: 0 };
data.sort((a, b) => (b.existingDup - a.existingDup) || (order[a.confidence] - order[b.confidence]) || a.category.localeCompare(b.category));

writeFileSync(`${ROOT}/review-data.json`, JSON.stringify(data, null, 2));
const byCat = {};
for (const d of data) byCat[d.category] = (byCat[d.category] || 0) + 1;
console.log(`review-data.json: ${data.length} items`);
console.log(`unclassified (fallback used): ${missing}, invalid-category fallbacks: ${badCat}`);
console.log(`by category:`, JSON.stringify(byCat));
console.log(`likely existing-dups: ${data.filter((d) => d.existingDup).length}, low-confidence: ${data.filter((d) => d.confidence === "low").length}`);
