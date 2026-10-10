// PreToolUse (Bash): deny a git add/stage/commit that names or has staged a secret file.
// Two layers: the command text itself, and on `git commit` the staged file list.
const { execSync } = require("node:child_process");
const path = require("node:path");
const ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");

const SECRET_RE =
  /(^|[\\/ "'=])env[\\/]|key\.properties|\.keystore|\.jks|google-services\.json|\.dev\.vars|(^|[\\/ "'])\.env($|[.\w]*)/i;

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
  if (!/git\s+(add|stage|commit)/.test(cmd)) return;

  if (/git\s+(add|stage)/.test(cmd) && SECRET_RE.test(cmd)) {
    return deny(
      "Blocked: command references a secret file (env/, *.keystore, *.jks, key.properties, google-services.json, .dev.vars, .env). Never stage secrets.",
    );
  }

  if (/git\s+commit/.test(cmd)) {
    let staged = "";
    try {
      staged = execSync("git diff --cached --name-only", { cwd: ROOT, encoding: "utf8", timeout: 10000 });
    } catch {
      return; // cannot inspect — do not block
    }
    const hits = staged.split(/\r?\n/).filter((f) => f && SECRET_RE.test(f));
    if (hits.length) {
      return deny(
        `Blocked: secret file(s) are staged: ${hits.join(", ")}. Unstage them (git restore --staged <file>) before committing.`,
      );
    }
  }
}

module.exports = { pre, SECRET_RE };
