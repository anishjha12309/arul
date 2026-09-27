// PostToolUse (Write|Edit): `dart format` the edited .dart file. Skips generated files. Silent, never blocks.
const { execSync } = require("node:child_process");

function post(input) {
  const file = input.tool_input?.file_path || input.tool_response?.filePath || "";
  if (!/\.dart$/i.test(file) || /\.(g|freezed)\.dart$/i.test(file) || file.includes('"')) return;
  try {
    execSync(`dart format "${file}"`, { stdio: "ignore", timeout: 20000 });
  } catch {
    /* a formatting failure must never block the edit */
  }
}

module.exports = { post };
