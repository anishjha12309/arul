// Apply {id, verdict:"delete"} decisions. Every touched file is rebuilt from HEAD, so a
// re-run is idempotent; blocks are cut bottom-up so offsets stay valid.
//   node apply.mjs out/decisions.jsonl [paths…]
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { OUT, ROOT, headText, lineEnd, lineStarts, lineOf, readJsonl, treeUsesCrlf } from './common.mjs';

const [decPath = join(OUT, 'decisions.jsonl'), ...paths] = process.argv.slice(2);
const inv = new Map(readJsonl(join(OUT, 'comments.jsonl')).map((b) => [b.id, b]));
const verdict = new Map();
for (const d of readJsonl(decPath)) verdict.set(d.id, d.verdict);

const byFile = new Map();
let refused = 0;
for (const [id, v] of verdict) {
  if (v !== 'delete') continue;
  const b = inv.get(id);
  if (!b) { console.error(`unknown id ${id}`); refused++; continue; }
  if (b.semantic) { console.error(`REFUSED semantic ${id}`); refused++; continue; }
  if (paths.length && !paths.some((p) => b.file.startsWith(p))) continue;
  if (!byFile.has(b.file)) byFile.set(b.file, []);
  byFile.get(b.file).push(b);
}
if (refused) process.exit(1);

const isWord = (ch) => ch !== undefined && /[\w$]/.test(ch);
const touched = [];
for (const [file, blocks] of byFile) {
  let text = headText(file);
  const starts = lineStarts(text);
  for (const b of blocks) {
    if (text.slice(b.offset, b.endOffset) !== b.text) throw new Error(`stale inventory for ${b.id}`);
  }
  blocks.sort((x, y) => y.offset - x.offset);
  for (const b of blocks) {
    const sl = lineOf(starts, b.offset);
    const el = lineOf(starts, b.endOffset - 1);
    const before = text.slice(starts[sl], b.offset);
    const after = text.slice(b.endOffset, lineEnd(text, b.endOffset));
    if (!b.trailing) {
      const from = starts[sl];
      const to = el + 1 < starts.length ? starts[el + 1] : text.length;
      text = text.slice(0, from) + text.slice(to);
      if (file.endsWith('.ts')) {
        // Collapse the blank-line run the cut may have joined.
        const prevBlank = from > 0 && /^\r?\n$/.test(text.slice(starts[Math.max(sl - 1, 0)], from)) && sl > 0;
        const nextLine = text.slice(from, lineEnd(text, from) + 2);
        if (prevBlank && /^\r?\n/.test(nextLine)) {
          const nl = text.indexOf('\n', from);
          text = text.slice(0, from) + text.slice(nl + 1);
        }
      }
    } else if (after.trim() === '') {
      let from = b.offset;
      while (from > starts[sl] && /[ \t]/.test(text[from - 1])) from--;
      text = text.slice(0, from) + text.slice(b.endOffset);
    } else {
      let to = b.endOffset;
      while (/[ \t]/.test(text[to] ?? '')) to++;
      let from = b.offset;
      if (before.trim() === '') { /* leading span on a code line: keep indentation */ }
      const glue = isWord(text[from - 1]) && isWord(text[to]) ? ' ' : '';
      text = text.slice(0, from) + glue + text.slice(to);
    }
  }
  writeFileSync(join(ROOT, file), treeUsesCrlf(file) ? text.replace(/\n/g, '\r\n') : text);
  touched.push(file);
}
const dart = touched.filter((f) => f.endsWith('.dart'));
for (let i = 0; i < dart.length; i += 40) {
  execSync(`dart format ${dart.slice(i, i + 40).map((f) => `"${f}"`).join(' ')}`, { cwd: ROOT, stdio: 'ignore' });
}
console.log(`applied ${[...byFile.values()].reduce((n, b) => n + b.length, 0)} deletions to ${touched.length} files`);
