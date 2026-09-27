// PreToolUse: a release appbundle (.aab, the Play artifact) must ship with FLAG_SECURE active in
// MainActivity.kt, so screenshots and recording stay blocked on the shipped app. A FLAG_SECURE that
// only survives inside a comment or a string does not count. APK and debug/profile builds are free.
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");
const MAIN_ACTIVITY = path.join(
  ROOT,
  "android",
  "app",
  "src",
  "main",
  "kotlin",
  "com",
  "hsrutility",
  "arul",
  "MainActivity.kt",
);

const isReleaseAabBuild = (cmd) =>
  /flutter\s+build\s+appbundle\b/.test(cmd) && !/--(debug|profile)\b/.test(cmd);

// One left-to-right pass drops comments and string literals together, so a delimiter is honoured only
// when it is not already inside something else ("https://host" must not open a comment). Anything
// unterminated runs to end of input and is dropped — the worst case is a false deny, never a false pass.
function stripCommentsAndStrings(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    if (src.startsWith("/*", i)) {
      const end = src.indexOf("*/", i + 2);
      i = end === -1 ? src.length : end + 2;
    } else if (src.startsWith("//", i)) {
      const end = src.indexOf("\n", i + 2);
      i = end === -1 ? src.length : end;
    } else if (src.startsWith('"""', i)) {
      const end = src.indexOf('"""', i + 3);
      i = end === -1 ? src.length : end + 3;
    } else if (src[i] === '"' || src[i] === "'") {
      const quote = src[i];
      i += 1;
      while (i < src.length && src[i] !== quote) {
        if (src[i] === "\\") i += 1;
        if (src[i] === "\n") break;
        i += 1;
      }
      i += 1;
    } else {
      out += src[i];
      i += 1;
    }
  }
  return out;
}

const hasActiveFlagSecure = (code) => /(setFlags|addFlags)\s*\([^)]*FLAG_SECURE/.test(code);

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

  let src;
  try {
    src = fs.readFileSync(MAIN_ACTIVITY, "utf8");
  } catch {
    // Fail CLOSED: if MainActivity cannot be read the .aab does not leave.
    return deny(
      `.aab build blocked: cannot read MainActivity.kt to verify FLAG_SECURE (${MAIN_ACTIVITY}). ` +
        `Restore the file or fix the guard path before building the .aab.`,
    );
  }
  if (!hasActiveFlagSecure(stripCommentsAndStrings(src))) {
    return deny(
      `.aab build blocked: FLAG_SECURE is not enabled in MainActivity.onCreate. The published .aab ` +
        `must block screenshots and screen recording. Add window.setFlags(FLAG_SECURE, FLAG_SECURE) ` +
        `in onCreate (uncommented), then retry.`,
    );
  }
}

module.exports = { pre, stripCommentsAndStrings, hasActiveFlagSecure };
