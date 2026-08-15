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

// Drop comments AND string/char literals in ONE left-to-right pass, so the check
// can only ever be satisfied by a call that actually compiles. Two things hide a
// dead FLAG_SECURE from a naive regex: a comment (the usual case — someone disables
// it for tester screenshots and forgets), and a string, e.g. a log line or a doc
// snippet that merely quotes `setFlags(FLAG_SECURE, FLAG_SECURE)`.
//
// The single pass is what makes it correct: regex-stripping comments first turns
// "https://host" into "https:, and a "//" living inside a string would swallow the
// real code after it. Scanning in order means a delimiter is only honoured when it
// is not already inside something else.
//
// Anything unterminated runs to end-of-input and is dropped, which can only REMOVE
// text — so the worst case is a false deny, never a false pass. That is the right
// direction to fail for the one artifact Play ships.
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
      // Raw string: no escapes, ends at the next triple quote.
      const end = src.indexOf('"""', i + 3);
      i = end === -1 ? src.length : end + 3;
    } else if (src[i] === '"' || src[i] === "'") {
      const quote = src[i];
      i += 1;
      while (i < src.length && src[i] !== quote) {
        if (src[i] === "\\") i += 1; // an escape consumes the char after it
        if (src[i] === "\n") break; // unterminated — stop at the line end
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

  if (!hasActiveFlagSecure(stripCommentsAndStrings(src))) {
    deny(
      `.aab build blocked: FLAG_SECURE is not enabled in MainActivity.onCreate. ` +
        `The published .aab must block screenshots + screen recording (anti-piracy). ` +
        `Add window.setFlags(FLAG_SECURE, FLAG_SECURE) in onCreate (uncommented), then retry.`,
    );
  }
});
