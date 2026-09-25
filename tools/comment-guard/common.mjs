// Shared by inventory, apply and verify: scope, HEAD reads and the two language scanners.
import { execFileSync, execSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scanTs } from './tokens_ts.mjs';

export const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = join(HERE, '..', '..');
export const OUT = join(HERE, 'out');
mkdirSync(OUT, { recursive: true });

export const inScope = (f) =>
  (/^lib\/.*\.dart$/.test(f) && !/\.(g|freezed)\.dart$/.test(f) && !f.startsWith('lib/app/l10n/')) ||
  /^workers\/src\/.*\.ts$/.test(f);

const git = (...args) =>
  execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 28 });

export const listFiles = (paths = ['lib', 'workers/src']) =>
  git('ls-files', '--', ...paths).split('\n').filter(Boolean).filter(inScope);

export const changedFiles = (paths = ['lib', 'workers/src']) =>
  git('diff', '--name-only', 'HEAD', '--', ...paths).split('\n').filter(Boolean).filter(inScope);

// core.autocrlf: HEAD holds LF, the working tree CRLF. Everything compares in LF, which
// is what a commit stores; apply writes the working tree's own line ending back.
export const headText = (f) => git('show', `HEAD:${f}`);
export const treeText = (f) => readFileSync(join(ROOT, f), 'utf8').replace(/\r\n/g, '\n');
export const treeUsesCrlf = (f) => {
  try {
    return readFileSync(join(ROOT, f), 'utf8').includes('\r\n');
  } catch {
    return false;
  }
};

// Semantic comments change the analyzer's or compiler's output; they are never deleted.
const SEMANTIC_LINE =
  /^\/\/[\/]?\s*(ignore:|ignore_for_file:|dart format (off|on)\b|coverage:|@dart\s*=|eslint-|@ts-|prettier-ignore|biome-ignore|<reference\b|# sourceMappingURL)/;
const SEMANTIC_BLOCK = /^\/\*\s*(eslint|global\s|@ts-|prettier-ignore|biome-ignore|istanbul|c8\s|v8\s)/;
export const isSemanticText = (t) => SEMANTIC_LINE.test(t) || SEMANTIC_BLOCK.test(t);

// entries: [{key, file, text}] → Map key → {tokens, comments:[{offset,end,text}]}
export function scan(entries) {
  const res = new Map();
  const dart = entries.filter((e) => e.file.endsWith('.dart'));
  for (const e of entries.filter((e) => e.file.endsWith('.ts'))) res.set(e.key, scanTs(e.file, e.text));
  // A fresh folder per call: Windows can still hold the last run's files open.
  for (const d of readdirSync(OUT)) {
    if (d.startsWith('snap-')) try { rmSync(join(OUT, d), { recursive: true, force: true }); } catch { /* still held */ }
  }
  const snap = mkdtempSync(join(OUT, 'snap-'));
  for (let i = 0; i < dart.length; i += 100) {
    const chunk = dart.slice(i, i + 100);
    const paths = chunk.map((e, j) => {
      const p = join(snap, `${i + j}.dart`);
      writeFileSync(p, e.text);
      return p;
    });
    let json;
    try {
      // `dart` is a .bat shim on Windows, so it needs a shell; every path here is ours.
      const cmd = `dart run tokens_dart.dart --json ${paths.map((a) => `"${a}"`).join(' ')}`;
      json = execSync(cmd, { cwd: HERE, encoding: 'utf8', maxBuffer: 1 << 28 });
    } catch (err) {
      throw new Error(`tokens_dart failed: ${err.stderr || err.message}`);
    }
    const parsed = JSON.parse(json);
    chunk.forEach((e, j) => res.set(e.key, parsed[paths[j]]));
  }
  try {
    rmSync(snap, { recursive: true, force: true });
  } catch {
    /* a held file stays until the next clean of out/ */
  }
  return res;
}

export const lineStarts = (text) => {
  const s = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === '\n') s.push(i + 1);
  return s;
};
export const lineOf = (starts, off) => {
  let lo = 0, hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= off) lo = mid; else hi = mid - 1;
  }
  return lo; // 0-based
};
export const lineEnd = (text, off) => {
  const n = text.indexOf('\n', off);
  const e = n < 0 ? text.length : n;
  return e > 0 && text[e - 1] === '\r' ? e - 1 : e;
};

export const readJsonl = (p) => {
  try {
    return readFileSync(p, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
};
