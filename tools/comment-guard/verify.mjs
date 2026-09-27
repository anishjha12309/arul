// Prove a comment-only edit: for every in-scope file that differs from the baseline, the
// non-comment token stream must be identical, every remaining comment must be a baseline comment
// (or an ordered subset of one block comment's lines) in order, and every semantic block must
// survive.
//   node verify.mjs [paths…]
import { join } from "node:path";
import {
  OUT,
  baseText,
  changedFiles,
  commentLineCount,
  isSemanticText,
  kindOf,
  langOf,
  readJsonl,
  scan,
  treeText,
} from "./common.mjs";

const paths = process.argv.slice(2);
const files = changedFiles(paths);
const entries = files.flatMap((f) => [
  { key: `B:${f}`, file: f, text: baseText(f) },
  { key: `W:${f}`, file: f, text: treeText(f) },
]);
let res;
try {
  res = scan(entries);
} catch (e) {
  console.log(`RED scan: ${e.message}`);
  process.exit(1);
}
const semantic = readJsonl(join(OUT, "comments.jsonl")).filter((b) => b.semantic);
// The tall-style formatter adds or drops a trailing comma when a list re-splits; that comma is the
// only token dart format may change, so it is compared separately.
const dropTrailingCommas = (t) => t.filter((x, i) => !(x === "," && [")", "]", "}", ">"].includes(t[i + 1])));
const norm = (s) =>
  s
    .split(/\r?\n/)
    .map((l) => l.trim())
    .join("\n");
// Content lines of a comment: trimmed, delimiters and empty lines dropped.
const content = (text) =>
  text
    .split(/\r?\n/)
    .map((l) =>
      l
        .trim()
        .replace(/^\/\*+|^\*+\/?|\*+\/$/g, "")
        .trim(),
    )
    .filter(Boolean);
const isSubsequence = (small, big) => {
  let i = 0;
  for (const x of big) if (i < small.length && small[i] === x) i++;
  return i === small.length;
};
// A tree comment is covered by a baseline comment when it is the same text, or the same block
// comment with some inner lines removed.
const covers = (b, w) => {
  if (norm(b.text) === norm(w.text)) return true;
  if (kindOf(b.text) !== "/*" || kindOf(w.text) !== "/*") return false;
  const cw = content(w.text);
  return cw.length > 0 && isSubsequence(cw, content(b.text));
};

let red = 0;
let before = 0,
  after = 0;
for (const f of files) {
  const b = res.get(`B:${f}`),
    w = res.get(`W:${f}`);
  const fail = (why) => {
    red++;
    console.log(`RED ${f} ${why}`);
  };
  if (b.skipped || w.skipped) {
    fail(`out of scope (${b.skipped || w.skipped})`);
    continue;
  }
  let note = "";
  if (b.tokens.join("\0") !== w.tokens.join("\0")) {
    const x = langOf(f) === "dart" ? dropTrailingCommas(b.tokens) : b.tokens;
    const y = langOf(f) === "dart" ? dropTrailingCommas(w.tokens) : w.tokens;
    if (x.join("\0") === y.join("\0")) {
      note = ` (formatter trailing commas ${b.tokens.length - x.length}->${w.tokens.length - y.length})`;
    } else {
      let i = 0;
      while (i < Math.max(b.tokens.length, w.tokens.length) && b.tokens[i] === w.tokens[i]) i++;
      fail(`token #${i}: base ${JSON.stringify(b.tokens[i])} vs tree ${JSON.stringify(w.tokens[i])}`);
      continue;
    }
  }
  let k = 0,
    bad = null;
  for (const c of w.comments) {
    while (k < b.comments.length && !covers(b.comments[k], c)) k++;
    if (k === b.comments.length) {
      bad = c.text;
      break;
    }
    k++;
  }
  if (bad) {
    fail(`comment not in baseline (reworded/added): ${JSON.stringify(bad.slice(0, 80))}`);
    continue;
  }
  const wc = w.comments.map((c) => norm(c.text)).join("\n");
  const lost = semantic.filter((s) => s.file === f).find((s) => !wc.includes(norm(s.text)));
  if (lost) {
    fail(`semantic block missing: ${lost.id}`);
    continue;
  }
  const semCount = (cs) => cs.filter((c) => isSemanticText(c.text)).length;
  if (semCount(b.comments) !== semCount(w.comments)) {
    fail("a semantic comment was removed");
    continue;
  }
  const cb = commentLineCount(baseText(f), b.comments),
    cw = commentLineCount(treeText(f), w.comments);
  before += cb;
  after += cw;
  console.log(`OK ${f} ${cb}->${cw}${note}`);
}
console.log(`${files.length} files, ${red} RED, comment lines ${before}->${after}`);
process.exit(red ? 1 : 0);
