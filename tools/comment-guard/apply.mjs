// Apply decisions. Every touched file is rebuilt from the baseline, so a re-run is idempotent;
// cuts are made bottom-up so offsets stay valid.
//   node apply.mjs [out/<scope>/decisions.jsonl] [paths…]
// A decision is {id, verdict} with verdict "keep" | "delete" | "trim". "trim" keeps a strict
// subset of the block's lines: {"verdict":"trim","keep":[2,3]} (1-based lines of the block as
// inventoried). For a /* */ block the opener and closer lines always stay and at least one inner
// line must be kept, so no text is ever written that the baseline did not hold.
import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { OUT, ROOT, baseText, lineEnd, lineOf, lineStarts, readJsonl, treeUsesCrlf } from "./common.mjs";

const [decPath = join(OUT, "decisions.jsonl"), ...paths] = process.argv.slice(2);
const inv = new Map(readJsonl(join(OUT, "comments.jsonl")).map((b) => [b.id, b]));
const decisions = new Map();
for (const d of readJsonl(decPath)) decisions.set(d.id, d);

const byFile = new Map();
let refused = 0;
const refuse = (id, why) => {
  console.error(`REFUSED ${id}: ${why}`);
  refused++;
};
for (const [id, d] of decisions) {
  if (d.verdict === "keep") continue;
  const b = inv.get(id);
  if (!b) {
    refuse(id, "unknown id");
    continue;
  }
  if (d.verdict !== "delete" && d.verdict !== "trim") {
    refuse(id, `verdict ${d.verdict}`);
    continue;
  }
  if (b.semantic) {
    refuse(id, "semantic");
    continue;
  }
  if (paths.length && !paths.some((p) => b.file.startsWith(p))) continue;
  if (d.verdict === "trim") {
    const keep = [...new Set(d.keep ?? [])].sort((x, y) => x - y);
    if (b.trailing) {
      refuse(id, "trim on a trailing comment");
      continue;
    }
    if (!keep.length || keep.some((k) => !Number.isInteger(k) || k < 1 || k > b.lines)) {
      refuse(id, `trim keep out of range 1..${b.lines}`);
      continue;
    }
    if (b.kind === "/*") {
      if (b.lines < 3) {
        refuse(id, "trim on a block comment under 3 lines");
        continue;
      }
      const inner = keep.filter((k) => k !== 1 && k !== b.lines);
      if (!inner.length) {
        refuse(id, "trim keeps no inner line");
        continue;
      }
      d.keep = [1, ...inner, b.lines];
    } else {
      d.keep = keep;
    }
    if (d.keep.length === b.lines) continue; // nothing to cut
  }
  if (!byFile.has(b.file)) byFile.set(b.file, []);
  byFile.get(b.file).push({ ...b, verdict: d.verdict, keep: d.keep });
}
if (refused) process.exit(1);

const isWord = (ch) => ch !== undefined && /[\w$]/.test(ch);
const touched = [];
let deleted = 0,
  trimmed = 0;
for (const [file, blocks] of byFile) {
  const base = baseText(file);
  const starts = lineStarts(base);
  for (const b of blocks) {
    if (base.slice(b.offset, b.endOffset) !== b.text) throw new Error(`stale inventory for ${b.id}`);
  }
  // Every cut is a [from, to) range of the baseline; whole lines for standalone blocks and trims.
  const cuts = [];
  const lineRange = (l) => [starts[l], l + 1 < starts.length ? starts[l + 1] : base.length];
  for (const b of blocks) {
    const sl = lineOf(starts, b.offset);
    const el = lineOf(starts, b.endOffset - 1);
    if (b.verdict === "trim") {
      const keep = new Set(b.keep.map((k) => sl + k - 1));
      for (let l = sl; l <= el; l++)
        if (!keep.has(l)) cuts.push({ from: starts[l], to: lineRange(l)[1], line: true });
      trimmed++;
      continue;
    }
    deleted++;
    if (!b.trailing) {
      cuts.push({ from: starts[sl], to: lineRange(el)[1], line: true });
      continue;
    }
    const after = base.slice(b.endOffset, lineEnd(base, b.endOffset));
    if (after.trim() === "") {
      let from = b.offset;
      while (from > starts[sl] && /[ \t]/.test(base[from - 1])) from--;
      cuts.push({ from, to: b.endOffset });
    } else {
      let to = b.endOffset;
      while (/[ \t]/.test(base[to] ?? "")) to++;
      const glue = isWord(base[b.offset - 1]) && isWord(base[to]) ? " " : "";
      cuts.push({ from: b.offset, to, glue });
    }
  }
  cuts.sort((x, y) => y.from - x.from);
  let text = base;
  for (const c of cuts) text = text.slice(0, c.from) + (c.glue ?? "") + text.slice(c.to);
  // A cut that joined two blank lines leaves a double blank; drop one. Cut positions stay valid
  // in descending order because every later cut sat above the one before it.
  for (const c of cuts) {
    if (!c.line) continue;
    const prevNl = text.lastIndexOf("\n", c.from - 1);
    const prevBlank = c.from > 0 && prevNl === c.from - 1 && (prevNl === 0 || text[prevNl - 1] === "\n");
    if (prevBlank && text[c.from] === "\n") text = text.slice(0, c.from) + text.slice(c.from + 1);
  }
  writeFileSync(join(ROOT, file), treeUsesCrlf(file) ? text.replace(/\n/g, "\r\n") : text);
  touched.push(file);
}
const dart = touched.filter((f) => f.endsWith(".dart"));
for (let i = 0; i < dart.length; i += 40) {
  execSync(
    `dart format ${dart
      .slice(i, i + 40)
      .map((f) => `"${f}"`)
      .join(" ")}`,
    { cwd: ROOT, stdio: "ignore" },
  );
}
console.log(`applied ${deleted} deletions and ${trimmed} trims to ${touched.length} files`);
