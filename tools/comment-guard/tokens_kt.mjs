// Comments and a whitespace-normalised code stream for Kotlin (.kt, .kts). A hand lexer is enough
// because only comment boundaries matter: strings (with `${}` templates, which may hold code and
// comments of their own), raw strings, char literals and backticked names are skipped as opaque code.
import { splitTokens } from "./tokens_text.mjs";

export function scanKt(text) {
  const comments = [];
  const n = text.length;
  let out = "";

  // Scans code from i; with `inTemplate` it returns just past the `}` that closes a `${`.
  function code(i, inTemplate) {
    let depth = 0;
    while (i < n) {
      const ch = text[i];
      const two = text.substr(i, 2);
      if (two === "//") {
        let j = text.indexOf("\n", i);
        if (j < 0) j = n;
        comments.push({ offset: i, end: j, text: text.slice(i, j) });
        out += " ";
        i = j;
      } else if (two === "/*") {
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
      } else if (text.startsWith('"""', i)) {
        i = string(i + 3, '"""');
      } else if (ch === '"') {
        i = string(i + 1, '"');
      } else if (ch === "'") {
        let j = i + 1;
        if (text[j] === "\\") j += 2;
        else j++;
        while (j < n && text[j] !== "'" && text[j] !== "\n") j++;
        out += text.slice(i, j + 1);
        i = j + 1;
      } else if (ch === "`") {
        let j = text.indexOf("`", i + 1);
        if (j < 0) j = n - 1;
        out += text.slice(i, j + 1);
        i = j + 1;
      } else {
        if (inTemplate) {
          if (ch === "{") depth++;
          else if (ch === "}") {
            if (depth === 0) {
              out += ch;
              return i + 1;
            }
            depth--;
          }
        }
        out += ch;
        i++;
      }
    }
    return i;
  }

  // Scans a string body from i to its closer; `${` recurses into code.
  function string(i, closer) {
    const raw = closer === '"""';
    out += closer;
    while (i < n) {
      if (text.startsWith(closer, i)) {
        // A raw string may end with extra quotes: `""""` closes with the LAST three.
        let j = i + closer.length;
        if (raw) while (text[j] === '"') j++;
        out += text.slice(i, j);
        return j;
      }
      if (!raw && text[i] === "\\") {
        out += text.substr(i, 2);
        i += 2;
        continue;
      }
      if (text[i] === "$" && text[i + 1] === "{") {
        out += "${";
        i = code(i + 2, true);
        continue;
      }
      out += text[i];
      i++;
    }
    return i;
  }

  code(0, false);
  return { tokens: splitTokens(out), comments };
}
