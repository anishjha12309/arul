// Prove a comment-only edit: for every in-scope file changed against HEAD, the
// non-comment token stream must be identical, every remaining comment must be an
// unaltered HEAD comment in order, and every semantic block must survive.
//   node verify.mjs [paths…]
import { join } from 'node:path';
import { OUT, changedFiles, headText, isSemanticText, readJsonl, scan, treeText } from './common.mjs';

const paths = process.argv.slice(2);
const files = changedFiles(paths.length ? paths : undefined);
const entries = files.flatMap((f) => [
  { key: `H:${f}`, file: f, text: headText(f) },
  { key: `W:${f}`, file: f, text: treeText(f) },
]);
let res;
try {
  res = scan(entries);
} catch (e) {
  console.log(`RED scan: ${e.message}`);
  process.exit(1);
}
const semantic = readJsonl(join(OUT, 'comments.jsonl')).filter((b) => b.semantic);
// The tall-style formatter adds or drops a trailing comma when a list re-splits; that
// comma is the only token dart format may change, so it is compared separately.
const dropTrailingCommas = (t) => t.filter((x, i) => !(x === ',' && [')', ']', '}', '>'].includes(t[i + 1])));
const norm = (s) => s.split(/\r?\n/).map((l) => l.trim()).join('\n');

let red = 0;
for (const f of files) {
  const h = res.get(`H:${f}`), w = res.get(`W:${f}`);
  const fail = (why) => { red++; console.log(`RED ${f} ${why}`); };
  let note = '';
  if (h.tokens.join('\0') !== w.tokens.join('\0')) {
    const a = dropTrailingCommas(h.tokens), b = dropTrailingCommas(w.tokens);
    if (a.join('\0') === b.join('\0')) {
      note = ` (formatter trailing commas ${h.tokens.length - a.length}->${w.tokens.length - b.length})`;
    } else {
      let i = 0;
      while (i < Math.max(h.tokens.length, w.tokens.length) && h.tokens[i] === w.tokens[i]) i++;
      fail(`token #${i}: HEAD ${JSON.stringify(h.tokens[i])} vs tree ${JSON.stringify(w.tokens[i])}`);
      continue;
    }
  }
  const hc = h.comments.map((c) => norm(c.text));
  let k = 0, bad = null;
  for (const c of w.comments) {
    const t = norm(c.text);
    while (k < hc.length && hc[k] !== t) k++;
    if (k === hc.length) { bad = c.text; break; }
    k++;
  }
  if (bad) { fail(`comment not in HEAD (reworded/added): ${JSON.stringify(bad.slice(0, 80))}`); continue; }
  const wc = w.comments.map((c) => norm(c.text)).join('\n');
  const lost = semantic.filter((b) => b.file === f).find((b) => !wc.includes(norm(b.text)));
  if (lost) { fail(`semantic block missing: ${lost.id}`); continue; }
  const semCount = (cs) => cs.filter((c) => isSemanticText(c.text)).length;
  if (semCount(h.comments) !== semCount(w.comments)) { fail('a semantic comment was removed'); continue; }
  console.log(`OK ${f}${note}`);
}
console.log(`${files.length} files, ${red} RED`);
process.exit(red ? 1 : 0);
