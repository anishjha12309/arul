// Comment scanners for the languages without a parser at hand: SQL and the `#`-comment family
// (YAML, TOML, Python, .properties). Each returns the comments plus a whitespace-normalised token
// stream of the code around them, which is all a comment-only proof needs to compare.

// Whitespace-split tokens; a run that holds a newline becomes one '\n' token, because Kotlin and
// YAML give a line break meaning that a space does not have.
export function splitTokens(stripped) {
  const tokens = [];
  let cur = "";
  let ws = null;
  for (const ch of stripped) {
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f" || ch === "\v") {
      if (cur) {
        tokens.push(cur);
        cur = "";
      }
      if (ch === "\n" || ch === "\r") ws = "\n";
      else ws ??= " ";
    } else {
      // A break before the first token or after the last means nothing, so neither is a token.
      if (ws) {
        if (ws === "\n" && tokens.length) tokens.push("\n");
        ws = null;
      }
      cur += ch;
    }
  }
  if (cur) tokens.push(cur);
  return tokens;
}

export function scanSql(text) {
  const comments = [];
  const n = text.length;
  let out = "";
  let i = 0;
  while (i < n) {
    const ch = text[i];
    if (ch === "-" && text[i + 1] === "-") {
      let j = text.indexOf("\n", i);
      if (j < 0) j = n;
      comments.push({ offset: i, end: j, text: text.slice(i, j) });
      out += " ";
      i = j;
    } else if (ch === "/" && text[i + 1] === "*") {
      let d = 1,
        j = i + 2;
      while (j < n && d > 0) {
        if (text.startsWith("/*", j)) {
          d++;
          j += 2;
        } else if (text.startsWith("*/", j)) {
          d--;
          j += 2;
        } else j++;
      }
      comments.push({ offset: i, end: j, text: text.slice(i, j) });
      out += " ";
      i = j;
    } else if (ch === "'") {
      // E'…' takes backslash escapes; a plain literal escapes a quote by doubling it.
      const esc = /[eE]$/.test(out) && !/\w[eE]$/.test(out);
      let j = i + 1;
      while (j < n) {
        if (esc && text[j] === "\\") {
          j += 2;
          continue;
        }
        if (text[j] === "'") {
          if (text[j + 1] === "'") {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      out += text.slice(i, j + 1);
      i = j + 1;
    } else if (ch === '"') {
      let j = i + 1;
      while (j < n) {
        if (text[j] === '"') {
          if (text[j + 1] === '"') {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      out += text.slice(i, j + 1);
      i = j + 1;
    } else if (ch === "$" && /^\$([A-Za-z_]\w*)?\$/.test(text.slice(i, i + 64))) {
      const tag = /^\$([A-Za-z_]\w*)?\$/.exec(text.slice(i, i + 64))[0];
      let j = text.indexOf(tag, i + tag.length);
      if (j < 0) j = n - tag.length;
      out += text.slice(i, j + tag.length);
      i = j + tag.length;
    } else {
      out += ch;
      i++;
    }
  }
  return { tokens: splitTokens(out), comments };
}

// ext: yaml | yml | toml | py | properties. A `#` opens a comment at line start or after whitespace
// (the YAML rule, which the others share); .properties only at line start, where `!` also counts.
export function scanHash(text, ext) {
  const comments = [];
  const n = text.length;
  const lineStartOnly = ext === "properties";
  const py = ext === "py";
  const toml = ext === "toml";
  const yaml = ext === "yaml" || ext === "yml";
  let out = "";
  let i = 0;
  let atLineStart = true;
  while (i < n) {
    const ch = text[i];
    if (ch === "\n") {
      out += ch;
      atLineStart = true;
      i++;
      continue;
    }
    if (ch === " " || ch === "\t" || ch === "\r") {
      out += ch;
      i++;
      continue;
    }
    const prev = i > 0 ? text[i - 1] : "\n";
    const opener = ch === "#" || (lineStartOnly && ch === "!");
    if (opener && (lineStartOnly ? atLineStart : atLineStart || /\s/.test(prev))) {
      let j = text.indexOf("\n", i);
      if (j < 0) j = n;
      comments.push({ offset: i, end: j, text: text.slice(i, j) });
      out += " ";
      i = j;
      continue;
    }
    atLineStart = false;
    if (!lineStartOnly && (ch === '"' || ch === "'")) {
      const triple = (py || toml) && text.startsWith(ch.repeat(3), i);
      const closer = triple ? ch.repeat(3) : ch;
      const escapes = ch === '"' || (py && ch === "'");
      let j = i + closer.length;
      while (j < n) {
        if (escapes && text[j] === "\\") {
          j += 2;
          continue;
        }
        if (text.startsWith(closer, j)) {
          if (yaml && ch === "'" && text[j + 1] === "'") {
            j += 2;
            continue;
          }
          j += closer.length;
          break;
        }
        if (!triple && !yaml && text[j] === "\n") break;
        j++;
      }
      out += text.slice(i, j);
      i = j;
      continue;
    }
    out += ch;
    i++;
  }
  return { tokens: splitTokens(out), comments };
}

// A YAML block scalar (`key: |` / `key: >`) can hold `#` lines that are content, not comments.
export const hasYamlBlockScalar = (text) => /:\s*[|>][-+0-9]*\s*(#.*)?$/m.test(text);
