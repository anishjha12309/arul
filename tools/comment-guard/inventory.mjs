// Inventory every comment block of the baseline into out/<scope>/comments.jsonl, plus readable
// out/<scope>/blocks-NN.md chunks for review.
//   node inventory.mjs --snapshot [paths…]   snapshot the working tree as the baseline, then inventory
//   node inventory.mjs [paths…]              inventory the existing baseline (default paths: whole repo)
//   node inventory.mjs --stats=base|tree     comment lines / total lines per folder
//   node inventory.mjs --stats=table         both, as a markdown table
// A block is one /* */, or consecutive standalone // (///, #, --) lines at one indentation.
// A trailing comment on a code line, and every semantic comment, is a block of its own.
import { readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  BASE,
  OUT,
  baseText,
  commentLineCount,
  hasBase,
  isSemanticText,
  kindOf,
  lineEnd,
  lineOf,
  lineStarts,
  listFiles,
  scan,
  snapshot,
  totalLines,
  treeText,
} from "./common.mjs";

// The comment is the only thing inside a {} — deleting it trips empty_catches / no-empty.
function soleBodyOfBraces(text, comments, i, j) {
  let p = comments[i].offset - 1;
  for (let k = i - 1; ; k--) {
    while (p >= 0 && /\s/.test(text[p])) p--;
    if (k >= 0 && comments[k].end - 1 === p) {
      p = comments[k].offset - 1;
      continue;
    }
    break;
  }
  let q = comments[j].end;
  for (let k = j + 1; ; k++) {
    while (q < text.length && /\s/.test(text[q])) q++;
    if (k < comments.length && comments[k].offset === q) {
      q = comments[k].end;
      continue;
    }
    break;
  }
  return text[p] === "{" && text[q] === "}";
}

export function blocksOf(file, text, comments) {
  const starts = lineStarts(text);
  const info = comments.map((c) => {
    const sl = lineOf(starts, c.offset);
    const el = lineOf(starts, c.end - 1);
    const before = text.slice(starts[sl], c.offset);
    const after = text.slice(c.end, lineEnd(text, c.end));
    const standalone = before.trim() === "" && after.trim() === "";
    return {
      ...c,
      sl,
      el,
      col: c.offset - starts[sl],
      kind: kindOf(c.text),
      standalone,
      sem: isSemanticText(c.text),
    };
  });
  const groups = [];
  for (let i = 0; i < info.length; i++) {
    const c = info[i];
    const g = groups.at(-1);
    const last = g && info[g.j];
    if (
      g &&
      c.kind !== "/*" &&
      last.kind === c.kind &&
      last.standalone &&
      c.standalone &&
      !last.sem &&
      !c.sem &&
      c.sl === last.el + 1 &&
      c.col === last.col
    ) {
      g.j = i;
    } else {
      groups.push({ i, j: i });
    }
  }
  return groups.map(({ i, j }) => {
    const a = info[i],
      b = info[j];
    const empty = soleBodyOfBraces(text, info, i, j);
    const sem = info.slice(i, j + 1).some((c) => c.sem) || empty;
    return {
      id: `${file}#${a.sl + 1}-${b.el + 1}`,
      file,
      start: a.sl + 1,
      end: b.el + 1,
      lines: b.el - a.sl + 1,
      trailing: !a.standalone,
      kind: a.kind,
      semantic: sem,
      ...(empty ? { why: "sole body of {}" } : {}),
      offset: a.offset,
      endOffset: b.end,
      text: text.slice(a.offset, b.end),
    };
  });
}

const folderOf = (f) => {
  const p = f.split("/");
  if (p.length === 1) return f;
  return p.slice(0, p[0] === "lib" && p[1] === "features" ? 3 : 2).join("/");
};

function stats(which) {
  const files = listFiles().filter((f) => which === "tree" || hasBase(f));
  const text = (f) => (which === "base" ? baseText(f) : treeText(f));
  const res = scan(files.map((f) => ({ key: f, file: f, text: text(f) })));
  const agg = {};
  for (const f of files) {
    const t = text(f);
    const k = folderOf(f);
    agg[k] ??= { comment: 0, total: 0 };
    agg[k].comment += commentLineCount(t, res.get(f).comments);
    agg[k].total += totalLines(t);
  }
  return agg;
}

function writeChunks(blocks) {
  for (const f of readdirSync(OUT)) if (/^blocks-\d+\.md$/.test(f)) unlinkSync(join(OUT, f));
  let n = 0,
    buf = "",
    file = null;
  const flush = () => {
    if (buf) writeFileSync(join(OUT, `blocks-${String(++n).padStart(2, "0")}.md`), buf);
    buf = "";
  };
  for (const b of blocks) {
    if (b.file !== file) {
      file = b.file;
      buf += `\n### ${file}\n`;
    }
    const flags = [b.semantic ? "semantic" : "", b.trailing ? "trailing" : ""].filter(Boolean).join(" ");
    buf += `- \`${b.id}\` ${b.lines}L ${b.kind}${flags ? ` [${flags}]` : ""}\n`;
    buf +=
      b.text
        .split("\n")
        .map((l) => `      ${l.trim()}`)
        .join("\n") + "\n";
    if (buf.length > 150_000) {
      flush();
      file = null;
    }
  }
  flush();
  return n;
}

const args = process.argv.slice(2);
const st = args.find((a) => a.startsWith("--stats"));
if (st) {
  const which = st.split("=")[1] ?? "tree";
  if (which === "table") {
    const b = stats("base"),
      t = stats("tree");
    const rows = [...new Set([...Object.keys(b), ...Object.keys(t)])].sort();
    let cb = 0,
      ct = 0,
      tb = 0,
      tt = 0;
    console.log("| folder | before (comment / total) | after | removed |\n|---|---:|---:|---:|");
    for (const k of rows) {
      const x = b[k] ?? { comment: 0, total: 0 },
        y = t[k] ?? { comment: 0, total: 0 };
      cb += x.comment;
      tb += x.total;
      ct += y.comment;
      tt += y.total;
      console.log(
        `| ${k} | ${x.comment} / ${x.total} | ${y.comment} / ${y.total} | ${x.comment - y.comment} |`,
      );
    }
    console.log(`| **total** | ${cb} / ${tb} | ${ct} / ${tt} | ${cb - ct} |`);
  } else {
    const agg = stats(which);
    writeFileSync(join(OUT, `stats-${which}.json`), JSON.stringify(agg, null, 1));
    let c = 0,
      t = 0;
    for (const [k, v] of Object.entries(agg).sort()) {
      console.log(`${k.padEnd(36)} ${String(v.comment).padStart(6)} / ${v.total}`);
      c += v.comment;
      t += v.total;
    }
    console.log(`${"TOTAL".padEnd(36)} ${String(c).padStart(6)} / ${t}`);
  }
} else {
  const snap = args.includes("--snapshot");
  const paths = args.filter((a) => !a.startsWith("--"));
  const files = listFiles(paths);
  if (snap) snapshot(files);
  const missing = files.filter((f) => !hasBase(f));
  if (missing.length) {
    console.error(`${missing.length} files have no baseline (first: ${missing[0]}); run with --snapshot`);
    process.exit(1);
  }
  const texts = new Map(files.map((f) => [f, baseText(f)]));
  const res = scan(files.map((f) => ({ key: f, file: f, text: texts.get(f) })));
  const out = [];
  const skipped = [];
  for (const f of files) {
    if (res.get(f).skipped) {
      skipped.push(`${f} (${res.get(f).skipped})`);
      continue;
    }
    out.push(...blocksOf(f, texts.get(f), res.get(f).comments));
  }
  writeFileSync(join(OUT, "comments.jsonl"), out.map((b) => JSON.stringify(b)).join("\n") + "\n");
  const chunks = writeChunks(out);
  const lines = out.reduce((n, b) => n + b.lines, 0);
  console.log(
    `${files.length} files, ${out.length} blocks (${lines} lines), ${out.filter((b) => b.semantic).length} semantic → ${OUT} (${chunks} review chunks)`,
  );
  if (skipped.length) console.log(`skipped: ${skipped.join(", ")}`);
  if (snap) console.log(`baseline: ${BASE}`);
}
