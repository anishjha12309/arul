// Stop hook: a turn that edited Dart must not end without an analyzer read.
// `flutter analyze` is ~5 MINUTES cold on this project -> an agent that skips it ships unanalysed
// code, and one that runs it every turn burns the session -> the gate accepts the Dart MCP's
// analyze_files (same analysis server, already warm, instant) and never runs an analyzer itself.
// Reminds by exit 2 -> Claude reads stderr and continues; stop_hook_active stops it looping.
const fs = require("node:fs");

const SEP = "[\\\\/]";
const DART_SRC = new RegExp(`(^|${SEP})(lib|test|integration_test)${SEP}.*\\.dart$`, "i");
const GENERATED = /\.(g|freezed)\.dart$/i;
// Auto mode edits through Bash as often as through Edit -> watch redirects and in-place seds too.
// The target must look like a PATH: a command that merely quotes this regex (or any .dart pattern)
// in its own text is not an edit, and an unanchored \S* matched exactly that once.
const PATHY = "[\"']?[A-Za-z0-9_./\\\\-]+\\.dart[\"']?";
const BASH_WRITES_DART = new RegExp(
  `(^|\\s)>{1,2}\\s*${PATHY}(\\s|$)|\\bsed\\b[^|\\n]{0,80}\\s-i[^|\\n]{0,80}\\s${PATHY}(\\s|$)` +
    `|\\btee\\b\\s+${PATHY}(\\s|$)`,
  "i",
);
const BASH_ANALYZES = /\b(flutter|dart)\s+analyze\b/i;

const basename = (p) => p.split("/").pop().split(String.fromCharCode(92)).pop();

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(raw);
  } catch {
    return;
  }
  if (input.stop_hook_active) return; // already continuing because of this gate -> let it end
  const path = input.transcript_path;
  if (!path || !fs.existsSync(path)) return;

  let lastEdit = -1;
  let lastAnalyze = -1;
  const edited = new Set();
  let i = 0;
  for (const line of fs.readFileSync(path, "utf8").split("\n")) {
    i++;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    const content = ev.message && ev.message.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (b.type !== "tool_use") continue;
      const name = b.name || "";
      const arg = b.input || {};
      if (/analyze_files$/.test(name)) lastAnalyze = i;
      if (name === "Bash" || name === "PowerShell") {
        const cmd = String(arg.command || "");
        if (BASH_ANALYZES.test(cmd)) lastAnalyze = i;
        if (BASH_WRITES_DART.test(cmd)) {
          const m = cmd.match(new RegExp(PATHY));
          if (m && !GENERATED.test(m[0])) {
            lastEdit = i;
            edited.add(basename(m[0]));
          }
        }
        continue;
      }
      const file = String(arg.file_path || "");
      if (/^(Edit|Write|NotebookEdit)$/.test(name) && DART_SRC.test(file) && !GENERATED.test(file)) {
        lastEdit = i;
        edited.add(basename(file));
      }
    }
  }

  if (lastEdit < 0 || lastAnalyze > lastEdit) return; // nothing to gate, or already analysed
  const names = [...edited].slice(-4).join(", ");
  process.stderr.write(
    `Dart edited (${names}) with no analyzer read since. Run mcp__dart__analyze_files ` +
      "(instant) before finishing — NOT `flutter analyze`, which is ~5 min cold here. " +
      "Fix what it reports, or say why it is acceptable.\n",
  );
  process.exit(2);
});
