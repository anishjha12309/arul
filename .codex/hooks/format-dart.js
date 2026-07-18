// PostToolUse (Write|Edit) hook: run `dart format` on the edited .dart file.
// Skips generated files. Silent on success; never blocks.
const { execSync } = require("node:child_process");

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let file = "";
  try {
    const j = JSON.parse(raw);
    file =
      (j.tool_input && j.tool_input.file_path) ||
      (j.tool_response && j.tool_response.filePath) ||
      "";
  } catch {
    return;
  }
  if (!/\.dart$/i.test(file)) return;
  if (/\.(g|freezed)\.dart$/i.test(file)) return;
  if (file.includes('"')) return;
  try {
    execSync(`dart format "${file}"`, { stdio: "ignore", timeout: 20000 });
  } catch {
    /* formatting failure must never block the edit */
  }
});
