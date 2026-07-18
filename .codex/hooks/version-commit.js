// PostToolUse (Write|Edit) hook: a pubspec version bump must never end up
// uncommitted (the reference app lost builds 17..20 that way). When `version:`
// differs from HEAD, commit the WHOLE tree under it — a build number labels a
// build = all the source that went into it. Modes (argv[2]): post — no-op unless
// pubspec.yaml was edited · check — same path for any file (seed a drifted tree).
const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = process.cwd();
const PUBSPEC = path.join(ROOT, "pubspec.yaml");

// Same regex as guard-secrets.js — refuse to commit if a secret is in the set.
const SECRET_RE =
  /(^|[\\/ "'=])env[\\/]|key\.properties|\.keystore|\.jks|google-services\.json|\.dev\.vars|(^|[\\/ "'])\.env($|[.\w]*)/i;

const git = (args, opts = {}) =>
  execSync(`git ${args}`, {
    encoding: "utf8", timeout: 20000, maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "ignore"], ...opts, // stdio: silence git's CRLF warnings
  });

const parseVersion = (text) => (text.match(/^version:\s*(\S+)/m) || [])[1] || null;

function report(message) {
  process.stdout.write(
    JSON.stringify({
      systemMessage: message,
      hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: message },
    }),
  );
}

function run() {
  const working = parseVersion(fs.readFileSync(PUBSPEC, "utf8"));
  if (!working) return;

  let committed = null;
  try {
    committed = parseVersion(git("show HEAD:pubspec.yaml"));
  } catch {
    return; // no HEAD yet (fresh repo) — nothing to compare against
  }
  if (working === committed) return;

  // porcelain lists exactly what `git add -A` would stage.
  const candidates = git("status --porcelain")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => line.slice(3).replace(/^"|"$/g, ""));
  if (!candidates.length) return;

  const secrets = candidates.filter((f) => SECRET_RE.test(f));
  if (secrets.length) {
    report(
      `Version bump to ${working} NOT committed: secret file(s) would be staged — ` +
        `${secrets.join(", ")}. These must be git-ignored (CLAUDE.md §9). Fix .gitignore, ` +
        `then re-run \`node .claude/hooks/version-commit.js check\`.`,
    );
    return;
  }

  const message = `build ${working}`; // one line; amend it to describe the work
  git("add -A");
  execSync("git commit -F -", {
    input: message,
    encoding: "utf8",
    timeout: 20000,
    stdio: ["pipe", "ignore", "ignore"],
  });
  const sha = git("rev-parse --short HEAD").trim();
  report(
    `Version bump ${committed} -> ${working} auto-committed as ${sha} ` +
      `(${candidates.length} file(s)). Amend the message to describe the work: git commit --amend`,
  );
}

const mode = process.argv[2] === "check" ? "check" : "post";
if (mode === "check") {
  try {
    run();
  } catch {} // a guard must never be the reason something breaks
} else {
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let file = "";
    try {
      const j = JSON.parse(raw);
      file = j.tool_input?.file_path || j.tool_response?.filePath || "";
    } catch {
      return;
    }
    if (path.basename(file).toLowerCase() !== "pubspec.yaml") return;
    try {
      run();
    } catch {} // an edit must never fail because the commit guard threw
  });
}
