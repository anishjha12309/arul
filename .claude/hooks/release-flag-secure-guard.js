// PreToolUse hook: a release **appbundle** build (.aab — the artifact published to
// Play) MUST ship with FLAG_SECURE enabled so screenshots + screen recording are
// blocked on the shipped app (anti-piracy — pairs with the share-time watermark;
// see MainActivity.kt).
//
// It reads MainActivity.kt, strips comments, and DENIES the .aab build unless an
// active setFlags/addFlags(FLAG_SECURE) call remains in source. A FLAG_SECURE that
// only survives inside a comment (e.g. temporarily disabled for tester screenshots)
// does NOT count — the guard blocks the .aab until it is re-enabled.
//
// Scope is the .aab ONLY. Sideload/prod APK and debug/profile builds are NOT
// guarded — you can still build a test APK with FLAG_SECURE off for screenshots.
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.cwd();
const MAIN_ACTIVITY = path.join(
  ROOT,
  "android", "app", "src", "main", "kotlin",
  "com", "hsrutility", "arul", "MainActivity.kt",
);

// Only the release .aab is gated. `flutter build appbundle` defaults to release;
// an explicit --debug/--profile appbundle is not a Play artifact, so skip it.
function isReleaseAabBuild(cmd) {
  return /flutter\s+build\s+appbundle\b/.test(cmd) && !/--(debug|profile)\b/.test(cmd);
}

// Strip // line comments and /* */ block comments so a FLAG_SECURE that only
// survives inside a comment can't satisfy the check.
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/[^\n]*/g, "");
}

// An active window flag: setFlags(...FLAG_SECURE...) or addFlags(...FLAG_SECURE...),
// possibly spanning multiple lines (the arg list has no ')' until after the flag).
function hasActiveFlagSecure(code) {
  return /(setFlags|addFlags)\s*\([^)]*FLAG_SECURE/.test(code);
}

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }),
  );
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let cmd = "";
  try {
    cmd = JSON.parse(raw).tool_input?.command || "";
  } catch {
    return; // unparseable payload — let it through
  }
  if (!isReleaseAabBuild(cmd)) return;

  let src;
  try {
    src = fs.readFileSync(MAIN_ACTIVITY, "utf8");
  } catch {
    // Fail CLOSED: a shipped .aab must have screenshots blocked; if we can't even
    // read MainActivity to confirm it, don't let the .aab out.
    deny(
      `.aab build blocked: cannot read MainActivity.kt to verify FLAG_SECURE ` +
        `(${MAIN_ACTIVITY}). The published app must block screenshots — restore the ` +
        `file or fix the guard path before building the .aab.`,
    );
    return;
  }

  if (!hasActiveFlagSecure(stripComments(src))) {
    deny(
      `.aab build blocked: FLAG_SECURE is not enabled in MainActivity.onCreate. ` +
        `The published .aab must block screenshots + screen recording (anti-piracy). ` +
        `Add window.setFlags(FLAG_SECURE, FLAG_SECURE) in onCreate (uncommented), then retry.`,
    );
  }
});
