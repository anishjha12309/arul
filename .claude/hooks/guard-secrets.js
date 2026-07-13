// PreToolUse (Bash|PowerShell) hook: block git add/commit that touches secrets.
// Two layers: (1) the command itself names a secret path; (2) on `git commit`,
// scan the staged file list. Deny = print permissionDecision JSON; allow = exit silently.
const { execSync } = require("node:child_process");

const SECRET_RE =
  /(^|[\\/ "'=])env[\\/]|key\.properties|\.keystore|\.jks|google-services\.json|\.dev\.vars|(^|[\\/ "'])\.env($|[.\w]*)/i;

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
    return;
  }
  if (!/git\s+(add|stage|commit)/.test(cmd)) return;

  if (/git\s+(add|stage)/.test(cmd) && SECRET_RE.test(cmd)) {
    deny(
      "Blocked: command references a secret file (env/, *.keystore, *.jks, key.properties, google-services.json, .dev.vars, .env). Never stage secrets.",
    );
    return;
  }

  if (/git\s+commit/.test(cmd)) {
    let staged = "";
    try {
      staged = execSync("git diff --cached --name-only", {
        encoding: "utf8",
        timeout: 10000,
      });
    } catch {
      return; // can't inspect — don't block
    }
    const hits = staged.split(/\r?\n/).filter((f) => f && SECRET_RE.test(f));
    if (hits.length) {
      deny(
        `Blocked: secret file(s) are staged: ${hits.join(", ")}. Unstage them (git restore --staged <file>) before committing.`,
      );
    }
  }
});
