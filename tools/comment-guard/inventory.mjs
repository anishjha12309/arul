// Inventory every comment block of HEAD's in-scope files into out/comments.jsonl.
//   node inventory.mjs [paths…]            blocks (default: lib workers/src)
//   node inventory.mjs --stats=head|tree   comment lines / total lines per top-level folder
// A block is one /* */, or consecutive standalone // (or ///) lines at one indentation.
// A trailing comment on a code line, and every semantic comment, is a block of its own.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  OUT, headText, treeText, inScope, isSemanticText, lineEnd, lineOf, lineStarts, listFiles, scan,
} from './common.mjs';

const kindOf = (t) => (t.startsWith('///') ? '///' : t.startsWith('//') ? '//' : '/*');

// The comment is the only thing inside a {} — deleting it trips empty_catches / no-empty.
function soleBodyOfBraces(text, comments, i, j) {
  let p = comments[i].offset - 1;
  for (let k = i - 1; ; k--) {
    while (p >= 0 && /\s/.test(text[p])) p--;
    if (k >= 0 && comments[k].end - 1 === p) { p = comments[k].offset - 1; continue; }
    break;
  }
  let q = comments[j].end;
  for (let k = j + 1; ; k++) {
    while (q < text.length && /\s/.test(text[q])) q++;
    if (k < comments.length && comments[k].offset === q) { q = comments[k].end; continue; }
    break;
  }
  return text[p] === '{' && text[q] === '}';
}

export function blocksOf(file, text, comments) {
  const starts = lineStarts(text);
  const info = comments.map((c) => {
    const sl = lineOf(starts, c.offset);
    const el = lineOf(starts, c.end - 1);
    const before = text.slice(starts[sl], c.offset);
    const after = text.slice(c.end, lineEnd(text, c.end));
    const standalone = before.trim() === '' && after.trim() === '';
    return { ...c, sl, el, col: c.offset - starts[sl], kind: kindOf(c.text), standalone,
      sem: isSemanticText(c.text) };
  });
  const groups = [];
  for (let i = 0; i < info.length; i++) {
    const c = info[i];
    const g = groups.at(-1);
    const last = g && info[g.j];
    if (g && c.kind !== '/*' && last.kind === c.kind && last.standalone && c.standalone &&
        !last.sem && !c.sem && c.sl === last.el + 1 && c.col === last.col) {
      g.j = i;
    } else {
      groups.push({ i, j: i });
    }
  }
  return groups.map(({ i, j }) => {
    const a = info[i], b = info[j];
    const empty = soleBodyOfBraces(text, info, i, j);
    const sem = info.slice(i, j + 1).some((c) => c.sem) || empty;
    return {
      id: `${file}#${a.sl + 1}-${b.el + 1}`,
      file, start: a.sl + 1, end: b.el + 1, trailing: !a.standalone, kind: a.kind,
      semantic: sem, ...(empty ? { why: 'sole body of {}' } : {}),
      offset: a.offset, endOffset: b.end, text: text.slice(a.offset, b.end),
    };
  });
}

function stats(which) {
  const files = listFiles();
  const res = scan(files.map((f) => ({ key: f, file: f, text: which === 'head' ? headText(f) : treeText(f) })));
  const agg = {};
  for (const f of files) {
    const text = which === 'head' ? headText(f) : treeText(f);
    const starts = lineStarts(text);
    const lines = new Set();
    for (const c of res.get(f).comments) {
      for (let l = lineOf(starts, c.offset); l <= lineOf(starts, c.end - 1); l++) lines.add(l);
    }
    const total = text.endsWith('\n') ? starts.length - 1 : starts.length;
    const top = f.startsWith('workers/') ? 'workers/src' : f.split('/').slice(0, f.startsWith('lib/features/') ? 3 : 2).join('/');
    agg[top] ??= { comment: 0, total: 0 };
    agg[top].comment += lines.size;
    agg[top].total += total;
  }
  return agg;
}

const args = process.argv.slice(2);
const st = args.find((a) => a.startsWith('--stats'));
if (st) {
  const which = st.split('=')[1] ?? 'head';
  const agg = stats(which);
  writeFileSync(join(OUT, `stats-${which}.json`), JSON.stringify(agg, null, 1));
  let c = 0, t = 0;
  for (const [k, v] of Object.entries(agg).sort()) {
    console.log(`${k.padEnd(32)} ${String(v.comment).padStart(6)} / ${v.total}`);
    c += v.comment; t += v.total;
  }
  console.log(`${'TOTAL'.padEnd(32)} ${String(c).padStart(6)} / ${t}`);
} else {
  const files = listFiles(args.length ? args : undefined).filter(inScope);
  const texts = new Map(files.map((f) => [f, headText(f)]));
  const res = scan(files.map((f) => ({ key: f, file: f, text: texts.get(f) })));
  const out = [];
  for (const f of files) out.push(...blocksOf(f, texts.get(f), res.get(f).comments));
  writeFileSync(join(OUT, 'comments.jsonl'), out.map((b) => JSON.stringify(b)).join('\n') + '\n');
  console.log(`${files.length} files, ${out.length} blocks, ${out.filter((b) => b.semantic).length} semantic`);
}
