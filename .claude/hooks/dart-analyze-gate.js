// Stop: a turn that edited Dart must not end without an analyzer read. `flutter analyze` is ~5 minutes
// cold here, so the gate accepts the Dart MCP's analyze_files (same analysis server, warm, instant) as
// well and never runs an analyzer itself. It holds the turn once (exit 2 + stderr); stop_hook_active
// stops it looping.
const fs = require("node:fs");

const SEP = "[\\\\/]";
const DART_SRC = new RegExp(`(^|${SEP})(lib|test|integration_test)${SEP}.*\\.dart$`, "i");
const GENERATED = /\.(g|freezed)\.dart$/i;
// Edits also arrive through Bash (redirects, in-place sed, tee). The target must look like a PATH so a
// command that merely quotes a .dart pattern is not counted as an edit.
const PATHY = "[\"']?[A-Za-z0-9_./\\\\-]+\\.dart[\"']?";
const BASH_WRITES_DART = new RegExp(
  `(^|\\s)>{1,2}\\s*${PATHY}(\\s|$)|\\bsed\\b[^|\\n]{0,80}\\s-i[^|\\n]{0,80}\\s${PATHY}(\\s|$)|\\btee\\b\\s+${PATHY}(\\s|$)`,
  "i",
);
const BASH_ANALYZES = /\b(flutter|dart)\s+analyze\b/i;
const basename = (p) => p.split("/").pop().split(String.fromCharCode(92)).pop();

function stop(input) {
  if (input.stop_hook_active) return;
  const transcript = input.transcript_path;
  if (!transcript || !fs.existsSync(transcript)) return;

  let lastEdit = -1;
  let lastAnalyze = -1;
  const edited = new Set();
  let i = 0;
  for (const line of fs.readFileSync(transcript, "utf8").split("\n")) {
    i++;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    const content = ev.message?.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (b.type !== "tool_use") continue;
      const name = b.name || "";
      const arg = b.input || {};
      if (/analyze_files$/.test(name)) lastAnalyze = i;
      if (name === "Bash") {
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
  if (lastEdit < 0 || lastAnalyze > lastEdit) return;
  const names = [...edited].slice(-4).join(", ");
  return {
    exit: 2,
    stderr:
      `Dart edited (${names}) with no analyzer read since. Run the Dart MCP analyze_files tool (instant) ` +
      "before finishing — NOT `flutter analyze`, which is ~5 min cold here. Fix what it reports, or say " +
      "why it is acceptable.\n",
  };
}

module.exports = { stop };
