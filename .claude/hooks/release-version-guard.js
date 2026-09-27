// Deny a release appbundle (.aab) whose pubspec version was already built from DIFFERENT source —
// "two builds, one versionCode" fails at the only place it matters, Play. APK builds never record
// state, so they rebuild at the same version freely.
//
// Recording is two-phase because a background build finishes long after PostToolUse fires:
//   pre        deny a stale-version build, else write pending.json hashing the source AS OF BUILD START
//   post       after every Bash call, promote pending → state once the .aab is newer than startedAt
//   reconcile  same promotion on Stop
//   seed       CLI only: record the current tree unconditionally
// State: git-ignored .claude/last-release-build.json (+ .pending.json).
const { execSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");
const STATE = path.join(ROOT, ".claude", "last-release-build.json");
const PENDING = path.join(ROOT, ".claude", "last-release-build.pending.json");
const ARTIFACTS = [path.join(ROOT, "build", "app", "outputs", "bundle", "release", "app-release.aab")];

const isReleaseAabBuild = (cmd) =>
  /flutter\s+build\s+appbundle\b/.test(cmd) && !/--(debug|profile)\b/.test(cmd);

function pubspecVersion() {
  const m = fs.readFileSync(path.join(ROOT, "pubspec.yaml"), "utf8").match(/^version:\s*(\S+)/m);
  if (!m) return null;
  const code = parseInt(m[1].split("+")[1] ?? "0", 10);
  return { version: m[1], code: Number.isNaN(code) ? 0 : code };
}

function sourceHash() {
  const git = (args) =>
    execSync(`git ${args}`, {
      cwd: ROOT,
      encoding: "utf8",
      timeout: 15000,
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
  const h = createHash("sha1");
  h.update(git("rev-parse HEAD"));
  h.update(git("status --porcelain"));
  h.update(git("diff HEAD"));
  // Untracked content is not in `diff HEAD`; fold in path, size and mtime.
  for (const f of git("ls-files --others --exclude-standard").split(/\r?\n/).filter(Boolean)) {
    try {
      const s = fs.statSync(path.join(ROOT, f));
      h.update(`${f}:${s.size}:${s.mtimeMs}\n`);
    } catch {}
  }
  return h.digest("hex");
}

const readJson = (p) => {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};
const writeState = (e) =>
  fs.writeFileSync(STATE, JSON.stringify({ ...e, at: new Date().toISOString() }, null, 2));

// Promote pending once its build produced an artifact. Idempotent, silent.
function reconcile() {
  const pending = readJson(PENDING);
  if (!pending) return;
  const produced = ARTIFACTS.some((a) => {
    try {
      return fs.statSync(a).mtimeMs > pending.startedAt;
    } catch {
      return false;
    }
  });
  if (!produced) return; // still building, or failed — leave pending in place
  writeState({ version: pending.version, code: pending.code, sourceHash: pending.sourceHash });
  try {
    fs.unlinkSync(PENDING);
  } catch {}
}

const deny = (reason) => ({
  stdout: {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  },
});

function pre(input) {
  const cmd = input.tool_input?.command || "";
  if (!isReleaseAabBuild(cmd)) return;
  const state = readJson(STATE);
  const v = pubspecVersion();
  if (!v) return; // unparseable pubspec — do not block
  const hash = sourceHash();
  if (state && v.code <= state.code && hash !== state.sourceHash) {
    return deny(
      `.aab build blocked: pubspec version is ${v.version} but ${state.version} was already built from ` +
        `DIFFERENT source (${state.at}). Bump the build number in pubspec.yaml ` +
        `(version: x.y.z+${state.code + 1}) before building the .aab, then retry.`,
    );
  }
  fs.writeFileSync(PENDING, JSON.stringify({ ...v, sourceHash: hash, startedAt: Date.now() }, null, 2));
}

function seed() {
  const v = pubspecVersion();
  if (v) writeState({ ...v, sourceHash: sourceHash() });
  try {
    fs.unlinkSync(PENDING);
  } catch {}
}

module.exports = { pre, post: reconcile, reconcile, seed };

if (require.main === module && process.argv[2] === "seed") {
  try {
    seed();
  } catch {}
}
