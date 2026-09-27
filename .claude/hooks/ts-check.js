// PostToolUse (Write|Edit) + Stop: the JS/TS twin of format-dart + dart-analyze-gate.
//   post  Biome `check --write` on the edited file (format + safe fixes, scoped by the root biome.jsonc, so an
//         out-of-scope file is a no-op); errors it cannot fix come back as context. Never blocks.
//   stop  a turn that edited JS/TS since the last pass runs `biome check` and, for workers/ TS, `tsc`; a
//         failure holds the turn once (exit 2). Biome and tsc are seconds here, so the gate runs them itself.
// Missing binary, timeout or any throw fails OPEN.
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");
const BIOME = path.join(ROOT, "workers", "node_modules", "@biomejs", "biome", "bin", "biome");
const TSC = path.join(ROOT, "workers", "node_modules", "typescript", "bin", "tsc");
const TSC_CWD = path.join(ROOT, "workers");
const JS_TS = /\.(ts|tsx|js|mjs|cjs)$/i;
const SKIP = /[\\/](node_modules|\.wrangler|dist)[\\/]/i;
// tsc covers workers/tsconfig.json's include only.
const TSC_SCOPE = /^workers[\\/](src|test)[\\/].*\.tsx?$/i;
const PATHY = "[\"']?[A-Za-z0-9_./\\\\-]+\\.(?:ts|tsx|js|mjs|cjs)[\"']?";
const BASH_WRITES = new RegExp(
  `(^|\\s)>{1,2}\\s*${PATHY}(\\s|$)|\\bsed\\b[^|\\n]{0,80}\\s-i[^|\\n]{0,80}\\s${PATHY}(\\s|$)|\\btee\\b\\s+${PATHY}(\\s|$)`,
  "i",
);

const run = (args, cwd, timeout) =>
  spawnSync(process.execPath, args, { cwd, encoding: "utf8", timeout, windowsHide: true });

// `--reporter=github` prints `::error title=<rule>,file=<f>,line=<n>,…::<message>` per diagnostic.
function biomeIssues(stdout) {
  const out = [];
  for (const line of String(stdout || "").split("\n")) {
    const m = line.match(/^::(error|warning) title=([^,]+),file=([^,]+),line=(\d+)[^:]*::(.*)$/);
    if (!m) continue;
    const file = path.relative(ROOT, decodeURIComponent(m[3])) || m[3];
    out.push(`${file}:${m[4]} ${m[2]} — ${m[5].trim()}`);
  }
  return out;
}

function post(input) {
  const file = input.tool_input?.file_path || input.tool_response?.filePath || "";
  if (!JS_TS.test(file) || SKIP.test(file) || !fs.existsSync(BIOME) || !fs.existsSync(file)) return;
  const args = [
    "--no-errors-on-unmatched",
    "--files-ignore-unknown=true",
    "--reporter=github",
    "--colors=off",
  ];
  const before = fs.readFileSync(file, "utf8");
  let r = run([BIOME, "check", "--write", ...args, file], ROOT, 20000);
  // A run that applied fixes exits 0 and reports nothing, even with errors left; re-read once.
  if (r.status === 0 && fs.readFileSync(file, "utf8") !== before)
    r = run([BIOME, "check", ...args, file], ROOT, 20000);
  if (r.status !== 1) return;
  const issues = biomeIssues(r.stdout);
  if (!issues.length) return;
  return {
    stdout: {
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: `Biome left ${issues.length} error(s) in ${path.basename(file)} after its safe fixes; fix them now:\n${issues.slice(0, 8).join("\n")}`,
      },
    },
  };
}

const statePath = (input) =>
  path.join(
    os.tmpdir(),
    `claude-ts-check-arul-${String(input.session_id || "x").replace(/[^\w-]/g, "")}.txt`,
  );

function stop(input) {
  if (input.stop_hook_active) return;
  const transcript = input.transcript_path;
  if (!transcript || !fs.existsSync(transcript) || !fs.existsSync(BIOME)) return;

  const lines = fs.readFileSync(transcript, "utf8").split("\n");
  let lastEdit = -1;
  let needTsc = false;
  const edited = new Set();
  lines.forEach((line, i) => {
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      return;
    }
    const content = ev.message?.content;
    if (!Array.isArray(content)) return;
    for (const b of content) {
      if (b.type !== "tool_use") continue;
      const arg = b.input || {};
      let file = "";
      if (b.name === "Bash" || b.name === "PowerShell") {
        const cmd = String(arg.command || "");
        if (BASH_WRITES.test(cmd)) file = (cmd.match(new RegExp(PATHY)) || [""])[0].replace(/["']/g, "");
      } else if (/^(Edit|Write)$/.test(b.name || "")) {
        file = String(arg.file_path || "");
      }
      if (!file || !JS_TS.test(file) || SKIP.test(file)) continue;
      lastEdit = i;
      edited.add(path.basename(file));
      if (TSC_SCOPE.test(path.relative(ROOT, path.resolve(ROOT, file)))) needTsc = true;
    }
  });

  const state = statePath(input);
  let passed = -1;
  try {
    passed = Number(fs.readFileSync(state, "utf8")) || -1;
  } catch {}
  if (lastEdit < 0 || lastEdit <= passed) return;

  const problems = [];
  const b = run(
    [BIOME, "check", ".", "--reporter=github", "--colors=off", "--max-diagnostics=20"],
    ROOT,
    30000,
  );
  if (b.status === 1) {
    const issues = biomeIssues(b.stdout);
    problems.push(
      ...(issues.length ? issues.slice(0, 10) : ["biome check failed (format?) — run it for details"]),
    );
  }
  if (needTsc && fs.existsSync(TSC)) {
    const t = run([TSC, "--noEmit"], TSC_CWD, 40000);
    if (t.status === 1 || t.status === 2) {
      problems.push(
        ...String(t.stdout || "")
          .split("\n")
          .filter((l) => /error TS\d+/.test(l))
          .slice(0, 10),
      );
    }
  }
  if (!problems.length) {
    try {
      fs.writeFileSync(state, String(lines.length));
    } catch {}
    return;
  }
  const names = [...edited].slice(-4).join(", ");
  return {
    exit: 2,
    stderr:
      `JS/TS edited (${names}) and the checks fail:\n${problems.join("\n")}\n` +
      "Fix them (`cd workers && npm run fix` applies format + safe fixes), or say why it is acceptable.\n",
  };
}

module.exports = { post, stop };
