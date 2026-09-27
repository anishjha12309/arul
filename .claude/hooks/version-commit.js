// PostToolUse (Write|Edit): a pubspec `version:` bump must never sit uncommitted (builds were lost that
// way). When it differs from HEAD, commit the WHOLE tree under it — a build number labels all the
// source that went into it. CLI `node .claude/hooks/version-commit.js check` runs the same path for a
// tree that drifted without an edit.
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { SECRET_RE } = require("./guard-secrets.js");

const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");
const PUBSPEC = path.join(ROOT, "pubspec.yaml");

const git = (args, opts = {}) =>
  execSync(`git ${args}`, {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 20000,
    maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
    ...opts,
  });
const parseVersion = (text) => (text.match(/^version:\s*(\S+)/m) || [])[1] || null;
const report = (message) => ({
  stdout: {
    systemMessage: message,
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: message },
  },
});

function run() {
  const working = parseVersion(fs.readFileSync(PUBSPEC, "utf8"));
  if (!working) return;
  let committed = null;
  try {
    committed = parseVersion(git("show HEAD:pubspec.yaml"));
  } catch {
    return; // no HEAD yet
  }
  if (working === committed) return;

  // porcelain lists exactly what `git add -A` would stage
  const candidates = git("status --porcelain")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => line.slice(3).replace(/^"|"$/g, ""));
  if (!candidates.length) return;

  const secrets = candidates.filter((f) => SECRET_RE.test(f));
  if (secrets.length) {
    return report(
      `Version bump to ${working} NOT committed: secret file(s) would be staged — ${secrets.join(", ")}. ` +
        `These must be git-ignored (CLAUDE.md §4). Fix .gitignore, then re-run ` +
        `\`node .claude/hooks/version-commit.js check\`.`,
    );
  }

  git("add -A");
  execSync("git commit -F -", {
    cwd: ROOT,
    input: `build ${working}`,
    encoding: "utf8",
    timeout: 20000,
    stdio: ["pipe", "ignore", "ignore"],
  });
  const sha = git("rev-parse --short HEAD").trim();
  return report(
    `Version bump ${committed} -> ${working} auto-committed as ${sha} (${candidates.length} file(s)). ` +
      `Amend the message to describe the work: git commit --amend`,
  );
}

function post(input) {
  const file = input.tool_input?.file_path || input.tool_response?.filePath || "";
  if (path.basename(file).toLowerCase() !== "pubspec.yaml") return;
  return run();
}

module.exports = { post, run };

if (require.main === module && process.argv[2] === "check") {
  try {
    const r = run();
    if (r) process.stdout.write(JSON.stringify(r.stdout));
  } catch {}
}
