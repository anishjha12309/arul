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
    docs: ["docs/phonepe.md"],
  },
  {
    when: ["workers/src/cron/**", "workers/wrangler.toml"],
    docs: ["docs/cron.md", "workers/README.md §Dev / deploy"],
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
    when: ["workers/src/routes/media.ts", "workers/src/lib/r2.ts", "workers/src/lib/media-constraints.ts", "workers/src/lib/media-verify.ts"],
    docs: ["docs/caching.md §Cache-Control written by this repo", "docs/media-conventions.md"],
  },
  {
    when: ["workers/src/routes/internal.ts", "lib/features/upload/**"],
    docs: ["docs/architecture.md §Uploads", "docs/edge-cases.md §Upload"],
  },
  // Must outrank the referral route below: the install-referrer service is one of
  // the THREE delivery paths for a wallpaper target (App Link, Play referrer,
  // Google Ads DDL) and they share one persisted one-shot, so a change to any of
  // them is a change to that contract. docs/deep-links.md had no route at all.
  {
    when: [
      "lib/core/deeplink/**",
      "lib/features/referral/data/install_referrer_service.dart",
      "lib/features/wallpapers/presentation/apply_restore.dart",
    ],
    docs: ["docs/deep-links.md", "docs/share.md §Attribution"],
  },
  {
    when: ["workers/src/lib/referral.ts", "lib/features/referral/**"],
    docs: ["docs/architecture.md §API", "docs/data-model.md"],
  },
  {
    when: ["workers/src/env.ts", "env.example.json"],
    docs: ["workers/README.md §Secrets", "CLAUDE.md §9 Secrets & Environment"],
  },
  {
    when: ["workers/src/routes/**", "workers/src/index.ts", "lib/core/api/**"],
    docs: ["docs/architecture.md §API", "workers/README.md"],
  },
  {
    when: ["db/schema/**", "db/seed.sql"],
    docs: ["docs/data-model.md", "docs/architecture.md §Schema"],
  },
  {
    when: ["lib/features/notifications/**"],
    docs: ["docs/notifications.md"],
  },
  {
    when: ["lib/core/analytics/**", "workers/src/lib/ga4.ts"],
    docs: ["docs/analytics-events.md", "docs/analytics-ops.md"],
  },
  {
    when: ["android/**/feedvideo/**", "lib/features/wallpapers/data/**"],
    docs: ["docs/edge-cases.md §Video feed", "docs/media-conventions.md §THE video rule"],
  },
  {
    when: ["android/**/MainActivity.kt", "android/app/src/main/AndroidManifest.xml", "android/**/wallpaper/**", "android/**/share/**"],
    docs: ["docs/edge-cases.md §Wallpaper apply", "docs/known-issues.md §Traps already paid for", "docs/share.md", "docs/deep-links.md §Google Ads DDL"],
  },
  {
    when: ["lib/features/wallpapers/**/*share*"],
    docs: ["docs/share.md", "docs/edge-cases.md §Share"],
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
  // The hooks are CODE, not prose — CLAUDE.md §11 and release-build/SKILL.md both
  // make claims about what they enforce, so changing one can silently contradict them.
  {
    when: [".claude/hooks/**"],
    docs: ["CLAUDE.md §11 Definition of Done & Git", ".claude/skills/release-build/SKILL.md"],
  },
  // LAST, and it must stay last — it is a catch-all, and first-match-wins means
  // anything above it wins. Seven of the twelve files in workers/src/lib were named
  // individually and the other five (db, ga4, media-verify, ratelimit, tombstone)
  // matched nothing at all, so editing a file two docs explicitly describe produced
  // no reminder. A general rule cannot rot as files are added; a list of names does.
  {
    when: ["workers/src/lib/**"],
    docs: ["docs/architecture.md", "workers/README.md"],
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
    // Prose only: docs/, the two root READMEs, and the skill/agent definitions.
    // .claude/hooks/ is deliberately NOT here — it is executable code that CLAUDE.md
    // §11 makes claims about, and suppressing the whole .claude/ tree is exactly how
    // the hooks drifted from the docs describing what they enforce.
    if (/^(docs\/|CLAUDE\.md$|README\.md$|\.claude\/(skills|agents)\/)/i.test(rel)) return;

    const relLower = rel.toLowerCase();
    for (const route of ROUTES) {
      const hit = route.when.find((p) => globToRegExp(p.toLowerCase()).test(relLower));
      if (!hit) continue;
      if (alreadyReminded(sessionId, hit)) return;
      const msg =
        `[doc-sync] ${hit} changed → ${route.docs.join(", ")}\n` +
        `Update the doc ONLY if a constraint changed: a new trap paid for on device, a changed ` +
        `contract, a dead end worth not repeating. Moved/restyled UI, copy tweaks, refactors, and ` +
        `anything readable from the code or the running app get NO doc update.`;
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
