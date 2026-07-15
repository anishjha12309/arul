// Split the 94 normalized items into batches for the vision classifiers.
// Each batch lists {base, path, kind, hintDup} — the image the agent should view.
import { readFileSync, writeFileSync, mkdirSync } from "fs";
const ROOT = "c:/Anish/arul-import";
mkdirSync(`${ROOT}/classify-batches`, { recursive: true });
const dedup = JSON.parse(readFileSync(`${ROOT}/dedup-manifest.json`, "utf8"));
const N = 6;

const items = dedup.map((d) => ({
  base: d.base,
  kind: d.kind,
  path: d.kind === "video" ? `normalized/thumbs/${d.base}.jpg` : `normalized/${d.out}`,
  hintDup: d.existingDup ? d.existMatch.category : null,
}));

const batches = Array.from({ length: N }, () => []);
items.forEach((it, i) => batches[i % N].push(it));
batches.forEach((b, i) => writeFileSync(`${ROOT}/classify-batches/batch-${i + 1}.json`, JSON.stringify(b, null, 2)));
console.log(`${items.length} items -> ${N} batches: ${batches.map((b) => b.length).join(", ")}`);
