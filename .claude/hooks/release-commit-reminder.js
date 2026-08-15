// PreToolUse + PostToolUse + Stop hook: a release artifact is only reproducible if
// the source that produced it is in git. After a SUCCESSFUL release build (.aab, or
// `flutter build apk --release`) that left files uncommitted, remind the agent to
// commit them. Reminder only — it never blocks a build or a turn.
//
// This is about the BUILD's accompanying source changes. version-commit.js already
// auto-commits a pubspec `version:` bump (and the whole tree with it), so the usual
// bump-then-build flow leaves a clean tree and this hook stays silent. It speaks up
// exactly when it should: a release built from source that nothing committed.
//
// Success is detected the same way release-version-guard.js does it, and for the
// same reason — PostToolUse fires the instant the tool call returns, which for a
// BACKGROUND build is minutes before Gradle writes the artifact. So:
//
//   pre       — the command is a release build: record which artifact(s) to watch
//               and the start time, in .claude/release-commit-reminder.pending.json.
//   post      — after every Bash call: if a watched artifact is newer than the
//               recorded start, the build succeeded → remind (if the tree is dirty)
//               and clear the record.
//   reconcile — same check, wired to Stop, for turns that end without another Bash
//               call (the background-build case).
//
// A failed build writes no artifact, so nothing is ever promoted and no reminder
// fires for it.
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.cwd();
const PENDING = path.join(ROOT, ".claude", "release-commit-reminder.pending.json");
const AAB = path.join(ROOT, "build", "app", "outputs", "bundle", "release", "app-release.aab");

// EVERY name a release APK can land under. The repo's own rule is
// `--split-per-abi --target-platform android-arm64` (release-build/SKILL.md §1),
// which writes app-arm64-v8a-release.apk and NEVER app-release.apk — so watching
// only the fat name meant the APK reminder could not fire at all. Watch the fat
// name too, for the emulator/x64 rebuild the same doc calls for.
const APKS = [
  "app-release.apk",
  "app-arm64-v8a-release.apk",
  "app-armeabi-v7a-release.apk",
  "app-x86_64-release.apk",
].map((n) => path.join(ROOT, "build", "app", "outputs", "flutter-apk", n));

// BOTH `flutter build appbundle` and `flutter build apk` default to release, so
// the absence of --debug/--profile is what marks a release artifact — requiring an
// explicit --release let a bare `flutter build apk` ship unreminded.
function watchedArtifacts(cmd) {
  if (/--(debug|profile)\b/.test(cmd)) return [];
  if (/flutter\s+build\s+appbundle\b/.test(cmd)) return [AAB];
  if (/flutter\s+build\s+apk\b/.test(cmd)) return APKS;
  return [];
}

const git = (args) =>
  execSync(`git ${args}`, {
    encoding: "utf8", timeout: 20000, maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"], // silence git's CRLF warnings
  });

const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
const clearPending = () => { try { fs.unlinkSync(PENDING); } catch {} };

function remind(message, hookEventName) {
  process.stdout.write(
    JSON.stringify({
      systemMessage: message,
      hookSpecificOutput: { hookEventName, additionalContext: message },
    }),
  );
}

// Fire the reminder once the pending build has actually produced its artifact.
function reconcile(hookEventName) {
  const pending = readJson(PENDING);
  if (!pending) return;

  const built = (pending.artifacts || []).find((a) => {
    try { return fs.statSync(a).mtimeMs > pending.startedAt; } catch { return false; }
  });
  if (!built) return; // still building (background) or the build failed — leave it pending

  clearPending();

  // Nothing uncommitted (version-commit.js already swept the tree, say) — say nothing.
  const dirty = git("status --porcelain").split(/\r?\n/).filter(Boolean);
  if (!dirty.length) return;

  const names = dirty.map((line) => line.slice(3).replace(/^"|"$/g, ""));
  const shown = names.slice(0, 8).join(", ");
  const rest = names.length > 8 ? `, +${names.length - 8} more` : "";
  remind(
    `${path.basename(built)} built from ${dirty.length} UNCOMMITTED file(s): ${shown}${rest}. ` +
      `A release artifact is only reproducible if its source is in git — commit them ` +
      `(one line, plain phrasing, no attribution trailers) once the human approves.`,
    hookEventName,
  );
}

const mode = process.argv[2];

// post/reconcile need no stdin — the Stop hook (which gets no tool payload) shares
// this path.
if (mode === "post" || mode === "reconcile") {
  try {
    reconcile(mode === "post" ? "PostToolUse" : "Stop");
  } catch {} // a reminder must never break the turn on its own errors
  process.exit(0);
}

// mode === "pre"
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let cmd = "";
  try { cmd = JSON.parse(raw).tool_input?.command || ""; } catch { return; }
  const artifacts = watchedArtifacts(cmd);
  if (!artifacts.length) return;
  try {
    fs.writeFileSync(PENDING, JSON.stringify({ artifacts, startedAt: Date.now() }, null, 2));
  } catch {} // never block a build because the reminder couldn't take a note
});
