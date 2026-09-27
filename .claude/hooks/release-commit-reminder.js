// A release artifact is only reproducible if the source that produced it is in git. After a
// SUCCESSFUL release build (.aab, or a release APK) that left files uncommitted, remind the agent to
// commit them. Reminder only — it never blocks a build or a turn, and never commits (the owner does).
//
// version-commit.js already commits the tree under a pubspec bump, so the bump-then-build flow leaves
// a clean tree and this stays silent. It speaks exactly when a release was built from source nothing
// committed. Success is detected like release-version-guard.js: PostToolUse fires the instant the tool
// returns, minutes before a background Gradle build writes its artifact, so:
//   pre        record which artifacts to watch and the start time in .claude/release-commit-reminder.pending.json
//   post       after every Bash call: a watched artifact newer than the start = success → remind if dirty
//   reconcile  same check on Stop (the background-build case)
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");
const PENDING = path.join(ROOT, ".claude", "release-commit-reminder.pending.json");
const AAB = path.join(ROOT, "build", "app", "outputs", "bundle", "release", "app-release.aab");
// Every name a release APK can land under: the repo builds `--split-per-abi --target-platform
// android-arm64`, which writes app-arm64-v8a-release.apk and never app-release.apk.
const APKS = [
  "app-release.apk",
  "app-arm64-v8a-release.apk",
  "app-armeabi-v7a-release.apk",
  "app-x86_64-release.apk",
].map((n) => path.join(ROOT, "build", "app", "outputs", "flutter-apk", n));

// Both `flutter build appbundle` and `flutter build apk` default to release, so the absence of
// --debug/--profile is what marks a release artifact.
function watchedArtifacts(cmd) {
  if (/--(debug|profile)\b/.test(cmd)) return [];
  if (/flutter\s+build\s+appbundle\b/.test(cmd)) return [AAB];
  if (/flutter\s+build\s+apk\b/.test(cmd)) return APKS;
  return [];
}

const git = (args) =>
  execSync(`git ${args}`, {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 20000,
    maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"],
  });
const readJson = (p) => {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

function reconcile(hookEventName = "Stop") {
  const pending = readJson(PENDING);
  if (!pending) return;
  const built = (pending.artifacts || []).find((a) => {
    try {
      return fs.statSync(a).mtimeMs > pending.startedAt;
    } catch {
      return false;
    }
  });
  if (!built) return; // still building or failed — leave it pending
  try {
    fs.unlinkSync(PENDING);
  } catch {}

  const dirty = git("status --porcelain").split(/\r?\n/).filter(Boolean);
  if (!dirty.length) return;
  const names = dirty.map((line) => line.slice(3).replace(/^"|"$/g, ""));
  const shown = names.slice(0, 8).join(", ");
  const rest = names.length > 8 ? `, +${names.length - 8} more` : "";
  const message =
    `${path.basename(built)} built from ${dirty.length} UNCOMMITTED file(s): ${shown}${rest}. ` +
    `A release artifact is only reproducible if its source is in git — commit them (one line, plain ` +
    `phrasing, no attribution trailers) once the owner approves.`;
  return {
    stdout: { systemMessage: message, hookSpecificOutput: { hookEventName, additionalContext: message } },
  };
}

function pre(input) {
  const cmd = input.tool_input?.command || "";
  const artifacts = watchedArtifacts(cmd);
  if (!artifacts.length) return;
  fs.writeFileSync(PENDING, JSON.stringify({ artifacts, startedAt: Date.now() }, null, 2));
}

module.exports = { pre, post: () => reconcile("PostToolUse"), reconcile: () => reconcile("Stop") };
