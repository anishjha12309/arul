// PostToolUse (Write|Edit) hook: name the doc that covers the file just edited.
//
// WHY: docs drift from code because nobody knows which doc covers what, and
// scanning docs/ to find out is expensive. This is a static route table, so the
// lookup is O(1): match the path, print the doc name, done.
//
// REMINDS, NEVER BLOCKS. Always exits 0. No match => prints nothing.
// Editing this table is the maintenance job — see .claude/skills/doc-update/.

// First match wins. Order specific -> general.
const ROUTES = [
  {
    when: ["workers/src/routes/payments.ts", "workers/src/lib/phonepe.ts"],
    docs: ["docs/phonepe.md", "docs/billing-verified.md"],
  },
  {
    when: ["workers/src/cron/**", "workers/wrangler.toml"],
    docs: ["docs/cron.md", "docs/provisioning.md §Cloudflare"],
  },
  {
    when: ["workers/src/lib/entitlement.ts", "lib/features/premium/**"],
    docs: ["CLAUDE.md §5 Premium Entitlement", "docs/architecture.md §Entitlement", "docs/edge-cases.md §Premium / payments"],
  },
  {
    when: ["workers/src/routes/auth.ts", "workers/src/lib/jwt.ts", "workers/src/lib/google.ts", "lib/features/auth/**"],
    docs: ["docs/architecture.md §Security", "docs/edge-cases.md §Auth"],
  },
  {
    when: ["workers/src/routes/media.ts", "workers/src/lib/r2.ts", "workers/src/lib/media-constraints.ts"],
    docs: ["docs/caching.md §Cache-Control written by this repo", "docs/media-conventions.md"],
  },
  {
    when: ["workers/src/routes/internal.ts", "lib/features/upload/**"],
    docs: ["docs/architecture.md §Uploads", "docs/edge-cases.md §Upload"],
  },
  {
    when: ["workers/src/lib/referral.ts", "lib/features/referral/**"],
    docs: ["docs/architecture.md §API", "docs/data-model.md"],
  },
  {
    when: ["workers/src/env.ts", "env.example.json"],
    docs: ["docs/provisioning.md", "CLAUDE.md §9 Secrets & Environment"],
  },
  {
    when: ["workers/src/routes/**", "workers/src/index.ts", "lib/core/api/**"],
    docs: ["docs/architecture.md §API", "workers/README.md"],
  },
  {
    when: ["db/schema/**", "db/seed.sql", "db/migrations/**"],
    docs: ["docs/data-model.md", "docs/architecture.md §Schema"],
  },
  {
    when: ["lib/core/analytics/**"],
    docs: ["docs/analytics-events.md", "docs/analytics-ops.md"],
  },
  {
    when: ["android/**/feedvideo/**", "lib/features/wallpapers/data/**"],
    docs: ["docs/edge-cases.md §Video feed", "docs/media-conventions.md §THE video rule"],
  },
  {
    when: ["android/**/MainActivity.kt", "android/app/src/main/AndroidManifest.xml", "android/**/wallpaper/**", "android/**/share/**"],
    docs: ["docs/edge-cases.md §Wallpaper apply", "docs/known-issues.md §Traps already paid for"],
  },
  {
    when: ["lib/theme/**", "lib/app/theme/**"],
    docs: ["docs/ui-direction.md", "CLAUDE.md §7 Theming"],
  },
  {
    when: ["lib/features/wallpapers/**"],
    docs: ["docs/edge-cases.md §Browse", "CLAUDE.md §5b Browse Model"],
  },
  {
    when: ["lib/features/ringtones/**"],
    docs: ["docs/edge-cases.md §Ringtones", "docs/architecture.md §API"],
  },
];

const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

const REPO_ROOT = path.resolve(__dirname, "..", "..");

function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        if (glob[i + 2] === "/") {
          re += "(?:.*/)?";
          i += 2;
        } else {
          re += ".*";
          i += 1;
        }
      } else {
        re += "[^/]*";
      }
    } else if (".+^${}()|[]\\?".includes(c)) {
      re += "\\" + c;
    } else {
      re += c;
    }
  }
  return new RegExp("^" + re + "$");
}

// Remind once per route per session, not once per file. Editing eight files in
// workers/src/cron/ should say "docs/cron.md" once.
function alreadyReminded(sessionId, key) {
  if (!sessionId) return false;
  const safe = String(sessionId).replace(/[^A-Za-z0-9._-]/g, "");
  if (!safe) return false;
  const f = path.join(os.tmpdir(), `doc-sync-arul-${safe}.txt`);
  try {
    const seen = fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n") : [];
    if (seen.includes(key)) return true;
    fs.appendFileSync(f, key + "\n");
  } catch {
    /* dedupe is best-effort; never let it suppress or crash the reminder */
  }
  return false;
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  try {
    let file = "";
    let sessionId = "";
    try {
      const j = JSON.parse(raw);
      file =
        (j.tool_input && j.tool_input.file_path) ||
        (j.tool_response && j.tool_response.filePath) ||
        "";
      sessionId = j.session_id || "";
    } catch {
      return;
    }
    if (!file) return;

    // Generated code carries no documented contract.
    if (/\.(g|freezed)\.dart$/i.test(file)) return;

    let rel = path.isAbsolute(file) ? path.relative(REPO_ROOT, file) : file;
    rel = rel.split(path.sep).join("/").replace(/^\.\//, "");
    // Outside the repo, or a doc edit (the doc IS the update) — say nothing.
    if (rel.startsWith("..")) return;
    if (/^(docs\/|CLAUDE\.md$|README\.md$|\.claude\/)/i.test(rel)) return;

    const relLower = rel.toLowerCase();
    for (const route of ROUTES) {
      const hit = route.when.find((p) => globToRegExp(p.toLowerCase()).test(relLower));
      if (!hit) continue;
      if (alreadyReminded(sessionId, hit)) return;
      const msg =
        `[doc-sync] ${hit} changed → ${route.docs.join(", ")}\n` +
        `Update it in this session if behaviour changed. Skip if this was a refactor.`;
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: msg,
          },
        })
      );
      return;
    }
  } catch {
    /* a doc reminder must never break a session */
  }
});
