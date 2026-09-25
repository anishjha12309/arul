// Non-comment token stream of a TypeScript file. The bare scanner cannot tell a regex
// from a slash or a template tail from a brace without the parser's re-scans, so this
// walks the parsed tree's leaf tokens; comments come from scanning the trivia before each
// leaf, which holds only whitespace and comments, so the bare scanner is exact there.
//
//   node tokens_ts.mjs <file>            one JSON-encoded token per line
//   import { scanTs } from './tokens_ts.mjs'
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../../workers/package.json', import.meta.url));
const ts = require('typescript');

export function scanTs(path, text = readFileSync(path, 'utf8')) {
  const sf = ts.createSourceFile(path, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  if (sf.parseDiagnostics.length) {
    const d = sf.parseDiagnostics[0];
    throw new Error(`${path}@${d.start}: ${ts.flattenDiagnosticMessageText(d.messageText, ' ')}`);
  }
  const tokens = [];
  const comments = new Map();
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, false, ts.LanguageVariant.Standard, text);
  const trivia = (pos, end) => {
    scanner.resetTokenState(pos);
    scanner.setText(text, pos, end - pos);
    for (let k = scanner.scan(); k !== ts.SyntaxKind.EndOfFileToken; k = scanner.scan()) {
      if (k !== ts.SyntaxKind.SingleLineCommentTrivia && k !== ts.SyntaxKind.MultiLineCommentTrivia) continue;
      const p = scanner.getTokenStart();
      comments.set(p, { offset: p, end: scanner.getTokenEnd(), text: scanner.getTokenText() });
    }
  };
  const visit = (node) => {
    if (node.kind >= ts.SyntaxKind.FirstJSDocNode && node.kind <= ts.SyntaxKind.LastJSDocNode) return;
    const kids = node.getChildren(sf);
    if (kids.length === 0 && node.kind !== ts.SyntaxKind.SyntaxList) {
      trivia(node.pos, node.getStart(sf));
      if (node.kind !== ts.SyntaxKind.EndOfFileToken) tokens.push(node.getText(sf));
      return;
    }
    kids.forEach(visit);
  };
  visit(sf);
  return { tokens, comments: [...comments.values()].sort((a, b) => a.offset - b.offset) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    for (const t of scanTs(process.argv[2]).tokens) console.log(JSON.stringify(t));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
