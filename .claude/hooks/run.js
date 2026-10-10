// One process per hook event. settings.json calls `node .claude/hooks/run.js <event>`; this reads the
// payload once and runs that event's modules in order, so a Bash call costs one spawn, not four.
//
//   pre-bash   PreToolUse  Bash  first `deny` wins and stops the chain
//   post-edit  PostToolUse Write|Edit       every module runs; their context lines are merged
//   post-bash  PostToolUse Bash  same
//   stop       Stop                         a module may hold the turn (exit 2 + stderr)
//
// A module exports plain functions of the parsed payload and returns undefined (silent) or
// { stdout?: object, stderr?: string, exit?: number }. A module that throws is skipped: a hook must
// never break a turn on its own error. Each module still has a CLI for its seed/check modes.
const path = require("node:path");

const EVENTS = {
  "pre-bash": [
    ["guard-secrets", "pre"],
    ["release-version-guard", "pre"],
    ["release-flag-secure-guard", "pre"],
    ["release-commit-reminder", "pre"],
  ],
  "post-edit": [
    ["format-dart", "post"],
    ["ts-check", "post"],
    ["version-commit", "post"],
    ["doc-sync-reminder", "post"],
  ],
  "post-bash": [
    ["release-version-guard", "post"],
    ["release-commit-reminder", "post"],
  ],
  stop: [
    ["release-version-guard", "reconcile"],
    ["release-commit-reminder", "reconcile"],
    ["dart-analyze-gate", "stop"],
    ["ts-check", "stop"],
  ],
};

const event = process.argv[2];
const steps = EVENTS[event];
if (!steps) {
  process.stderr.write(`run.js: unknown hook event "${event}"\n`);
  process.exit(0);
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let input = {};
  try {
    input = raw.trim() ? JSON.parse(raw) : {};
  } catch {
    input = {};
  }

  const contexts = [];
  const systemMessages = [];
  let hold = null;

  for (const [name, fn] of steps) {
    let result;
    try {
      result = require(path.join(__dirname, `${name}.js`))[fn](input);
    } catch {
      continue;
    }
    if (!result) continue;
    if (result.exit === 2) {
      hold = hold || result;
      continue;
    }
    const out = result.stdout;
    if (!out) continue;
    const hso = out.hookSpecificOutput || {};
    if (hso.permissionDecision) {
      process.stdout.write(JSON.stringify(out));
      return; // a deny ends the chain
    }
    if (hso.additionalContext) contexts.push(hso.additionalContext);
    if (out.systemMessage) systemMessages.push(out.systemMessage);
  }

  if (hold) {
    process.stderr.write(hold.stderr || "");
    process.exit(2);
  }
  if (!contexts.length && !systemMessages.length) return;
  const eventName = event === "stop" ? "Stop" : "PostToolUse";
  const out = {};
  if (systemMessages.length) out.systemMessage = systemMessages.join("\n");
  if (contexts.length) {
    out.hookSpecificOutput = { hookEventName: eventName, additionalContext: contexts.join("\n") };
  }
  process.stdout.write(JSON.stringify(out));
});
