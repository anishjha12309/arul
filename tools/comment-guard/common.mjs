// Shared by inventory, apply and verify: the repo root, the scope's output folder, the baseline
// snapshot and the per-language scanners.
//   CG_ROOT   repo to work in (default: this repo); the CMS is `CG_ROOT="$HOME/Anish/Unified CMS"`
//   CG_SCOPE  output folder name under out/, so two culls can run side by side
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  writeFileSync,
  rmSync,
} from "node:fs";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { scanTs } from "./tokens_ts.mjs";
import { scanKt } from "./tokens_kt.mjs";
import { hasYamlBlockScalar, scanHash, scanSql } from "./tokens_text.mjs";

export const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = process.env.CG_ROOT ? resolve(process.env.CG_ROOT) : join(HERE, "..", "..");
export const SCOPE = process.env.CG_SCOPE || "default";
export const OUT = join(HERE, "out", SCOPE);
export const BASE = join(OUT, "base");
mkdirSync(BASE, { recursive: true });

const EXT = /\.(dart|ts|tsx|js|mjs|cjs|kt|kts|sql|py|yaml|yml|toml|properties)$/;
const EXCLUDE =
  /(^|\/)(node_modules|third_party|build|dist|\.wrangler|\.dart_tool|__pycache__)\/|^src\/vendor\/|^tools\/comment-guard\/|\.(g|freezed)\.dart$|^lib\/app\/l10n\/|worker-configuration\.d\.ts$/;
export const inScope = (f) => EXT.test(f) && !EXCLUDE.test(f);

export const extOf = (f) => extname(f).slice(1);
export const langOf = (f) => {
  const e = extOf(f);
  if (["ts", "tsx", "js", "mjs", "cjs"].includes(e)) return "ts";
  if (e === "kts") return "kt";
  if (["yaml", "yml", "toml", "py", "properties"].includes(e)) return "hash";
  return e;
};

const git = (...args) => execFileSync("git", args, { cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 28 });

export const listFiles = (paths = []) =>
  git("ls-files", "--", ...(paths.length ? paths : ["."]))
    .split("\n")
    .filter(Boolean)
    .filter(inScope);

// Everything compares in LF; apply writes the working tree's own line ending back.
export const normLf = (s) => s.replace(/\r\n/g, "\n");
export const treeText = (f) => normLf(readFileSync(join(ROOT, f), "utf8"));
export const treeUsesCrlf = (f) => {
  try {
    return readFileSync(join(ROOT, f), "utf8").includes("\r\n");
  } catch {
    return false;
  }
};

// The baseline is a snapshot of the working tree taken by `inventory.mjs --snapshot`, not HEAD:
// the tree carries uncommitted work that a rebuild from HEAD would silently throw away.
const basePath = (f) => join(BASE, f);
export const hasBase = (f) => existsSync(basePath(f));
export const baseText = (f) => {
  try {
    return readFileSync(basePath(f), "utf8");
  } catch {
    throw new Error(`no baseline for ${f}: run inventory.mjs --snapshot first`);
  }
};
export function snapshot(files) {
  rmSync(BASE, { recursive: true, force: true });
  for (const f of files) {
    mkdirSync(dirname(basePath(f)), { recursive: true });
    writeFileSync(basePath(f), treeText(f));
  }
}
export const changedFiles = (paths = []) =>
  listFiles(paths).filter((f) => hasBase(f) && treeText(f) !== baseText(f));

// Semantic comments change a tool's output; they are never deleted or trimmed.
const SEMANTIC =
  /^(#!|(\/\/\/?|#|--)\s*(ignore:|ignore_for_file:|dart format (off|on)\b|coverage:|@dart\s*=|eslint-|@ts-|prettier-ignore|biome-ignore|<reference\b|# sourceMappingURL|noinspection|ktlint-|detekt|@formatter:(off|on)|noqa|type:|pylint:|fmt:\s*(off|on)|yaml-language-server|-\*-)|\/\*\s*(eslint|global\s|@ts-|prettier-ignore|biome-ignore|istanbul|c8\s|v8\s))/;
export const isSemanticText = (t) => SEMANTIC.test(t);

export const kindOf = (t) =>
  t.startsWith("///")
    ? "///"
    : t.startsWith("//")
      ? "//"
      : t.startsWith("/*")
        ? "/*"
        : t.startsWith("--")
          ? "--"
          : "#";

// entries: [{key, file, text}] → Map key → {tokens, comments:[{offset,end,text}]}
export function scan(entries) {
  const res = new Map();
  const dart = [];
  for (const e of entries) {
    switch (langOf(e.file)) {
      case "dart":
        dart.push(e);
        break;
      case "ts":
        res.set(e.key, scanTs(e.file, e.text));
        break;
      case "kt":
        res.set(e.key, scanKt(e.text));
        break;
      case "sql":
        res.set(e.key, scanSql(e.text));
        break;
      case "hash":
        if (/ya?ml$/.test(e.file) && hasYamlBlockScalar(e.text)) {
          res.set(e.key, { tokens: splitAll(e.text), comments: [], skipped: "yaml block scalar" });
        } else {
          res.set(e.key, scanHash(e.text, extOf(e.file)));
        }
        break;
      default:
        throw new Error(`no scanner for ${e.file}`);
    }
  }
  if (dart.length) scanDart(dart, res);
  return res;
}
const splitAll = (t) => t.split(/\s+/).filter(Boolean);

function scanDart(dart, res) {
  // A fresh folder per call inside this scope's out/: a previous run's leftovers never mix into this one.
  for (const d of readdirSync(OUT)) {
    if (d.startsWith("snap-"))
      try {
        rmSync(join(OUT, d), { recursive: true, force: true });
      } catch {
        /* still held */
      }
  }
  const snap = mkdtempSync(join(OUT, "snap-"));
  for (let i = 0; i < dart.length; i += 100) {
    const chunk = dart.slice(i, i + 100);
    const paths = chunk.map((e, j) => {
      const p = join(snap, `${i + j}.dart`);
      writeFileSync(p, e.text);
      return p;
    });
    let json;
    try {
      json = execFileSync("dart", ["run", "tokens_dart.dart", "--json", ...paths], {
        cwd: HERE,
        encoding: "utf8",
        maxBuffer: 1 << 28,
      });
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
}

export const lineStarts = (text) => {
  const s = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") s.push(i + 1);
  return s;
};
export const lineOf = (starts, off) => {
  let lo = 0,
    hi = starts.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= off) lo = mid;
    else hi = mid - 1;
  }
  return lo; // 0-based
};
export const lineEnd = (text, off) => {
  const n = text.indexOf("\n", off);
  const e = n < 0 ? text.length : n;
  return e > 0 && text[e - 1] === "\r" ? e - 1 : e;
};
export const commentLineCount = (text, comments) => {
  const starts = lineStarts(text);
  const lines = new Set();
  for (const c of comments) {
    for (let l = lineOf(starts, c.offset); l <= lineOf(starts, c.end - 1); l++) lines.add(l);
  }
  return lines.size;
};
export const totalLines = (text) => {
  const s = lineStarts(text);
  return text.endsWith("\n") ? s.length - 1 : s.length;
};

export const readJsonl = (p) => {
  try {
    return readFileSync(p, "utf8")
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => JSON.parse(l));
  } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
};
