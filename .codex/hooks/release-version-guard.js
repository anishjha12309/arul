// Release-build version guard: deny a flutter RELEASE build (apk/appbundle) whose
// pubspec version was already built from DIFFERENT source — catches "two builds,
// same versionCode" while allowing the AAB+APK pair from identical source.
// State: git-ignored .claude/last-release-build.json. Recording is TWO-PHASE
// (background builds finish long after PostToolUse fires): pre — deny stale-version
// builds, else write pending.json hashing the source AS OF BUILD START (that is what
// gets compiled) · post — after every Bash call, promote pending → state once an
// artifact is newer than pending.startedAt (a failed build never promotes) ·
// reconcile — same promotion, wired to Stop · seed — record unconditionally.
const { execSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.cwd();
const STATE = path.join(ROOT, ".claude", "last-release-build.json");
const PENDING = path.join(ROOT, ".claude", "last-release-build.pending.json");
const ARTIFACTS = [
  path.join(ROOT, "build", "app", "outputs", "bundle", "release", "app-release.aab"),
  path.join(ROOT, "build", "app", "outputs", "flutter-apk", "app-release.apk"),
];

const isReleaseBuild = (cmd) =>
  /flutter\s+build\s+(apk|appbundle)\b/.test(cmd) && !/--(debug|profile)\b/.test(cmd);

function pubspecVersion() {
  const m = fs.readFileSync(path.join(ROOT, "pubspec.yaml"), "utf8").match(/^version:\s*(\S+)/m);
  if (!m) return null;
  const code = parseInt(m[1].split("+")[1] ?? "0", 10);
  return { version: m[1], code: Number.isNaN(code) ? 0 : code };
}

function sourceHash() {
  const git = (args) =>
    execSync(`git ${args}`, { encoding: "utf8", timeout: 15000, maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "ignore"] });
  const h = createHash("sha1");
  h.update(git("rev-parse HEAD"));
  h.update(git("status --porcelain"));
  h.update(git("diff HEAD"));
  // Untracked CONTENT isn't in `diff HEAD`; fold in path+size+mtime instead.
  for (const f of git("ls-files --others --exclude-standard").split(/\r?\n/).filter(Boolean)) {
    try { const s = fs.statSync(path.join(ROOT, f)); h.update(`${f}:${s.size}:${s.mtimeMs}\n`); } catch {}
  }
  return h.digest("hex");
}

const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
const writeState = (e) => fs.writeFileSync(STATE, JSON.stringify({ ...e, at: new Date().toISOString() }, null, 2));

// Promote pending once its build actually produced an artifact. Idempotent, silent.
function reconcile() {
  const pending = readJson(PENDING);
  if (!pending) return;
  const produced = ARTIFACTS.some((a) => { try { return fs.statSync(a).mtimeMs > pending.startedAt; } catch { return false; } });
  if (!produced) return; // still building (background) or failed — leave pending in place
  writeState({ version: pending.version, code: pending.code, sourceHash: pending.sourceHash });
  try { fs.unlinkSync(PENDING); } catch {}
}

const deny = (reason) =>
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } }));

const mode = process.argv[2];

if (mode === "seed") {
  const v = pubspecVersion(); if (v) writeState({ ...v, sourceHash: sourceHash() });
  try { fs.unlinkSync(PENDING); } catch {}
  process.exit(0);
}

// post/reconcile need no stdin — the Stop hook (no tool payload) shares this path.
if (mode === "post" || mode === "reconcile") {
  try { reconcile(); } catch {} // a guard must never break the turn on its own errors
  process.exit(0);
}

// mode === "pre"
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let cmd = "";
  try { cmd = JSON.parse(raw).tool_input?.command || ""; } catch { return; }
  if (!isReleaseBuild(cmd)) return;
  try {
    const state = readJson(STATE);
    const v = pubspecVersion();
    if (!v) return; // unparseable pubspec — don't block
    const hash = sourceHash();
    if (state && v.code <= state.code && hash !== state.sourceHash) {
      deny(
        `Release build blocked: pubspec version is ${v.version} but ${state.version} was already built ` +
          `from DIFFERENT source (${state.at}). Bump the build number in pubspec.yaml ` +
          `(version: x.y.z+${state.code + 1}) before building, then retry.`,
      );
      return;
    }
    // Allowed: capture the source being compiled RIGHT NOW; reconcile promotes it later.
    fs.writeFileSync(PENDING, JSON.stringify({ ...v, sourceHash: hash, startedAt: Date.now() }, null, 2));
  } catch {} // guard must never break a build on its own errors (git missing etc.)
});
