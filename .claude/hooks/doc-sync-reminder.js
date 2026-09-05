// Nobody knows which doc covers what -> scanning docs/ is expensive -> match the edited path against
// a static table and print the doc name.
// Reminds, never blocks -> always exits 0 -> no match prints nothing.
// The table IS the maintenance job -> keep it in step with .claude/rules/ globs -> see
// .claude/skills/doc-update/.

// First match wins. Order specific -> general.
const ROUTES = [
  {
    when: [
      "android/app/src/main/res/values*/styles.xml",
      "android/app/src/main/res/drawable*/launch_background.xml",
      "lib/features/auth/presentation/widgets/video_background.dart",
      "lib/features/auth/presentation/splash_screen.dart",
    ],
    docs: ["docs/launch-surface.md"],
  },
  {
    when: ["lib/main.dart", "android/app/proguard-rules.pro", "lib/core/perf/**"],
    docs: [
      ".claude/skills/on-device/SKILL.md (release-silence contract)",
      "docs/perf-measurement.md",
      "docs/launch-surface.md §Dead ends",
    ],
  },
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
    when: [
      "workers/src/routes/auth.ts",
      "workers/src/lib/jwt.ts",
      "workers/src/lib/google.ts",
      "lib/features/auth/**",
      "lib/core/auth/**",
    ],
    docs: ["docs/auth.md", "docs/architecture.md §Security"],
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
    docs: ["workers/README.md §Secrets", "CLAUDE.md §6 Secrets & environment"],
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
    when: ["lib/core/analytics/**", "workers/src/lib/posthog.ts"],
    docs: ["docs/analytics-events.md", "docs/analytics-ops.md", "docs/google-ads.md"],
  },
  {
    when: [
      "android/**/feedvideo/**",
      "lib/features/wallpapers/data/**",
      "lib/features/wallpapers/presentation/video_preload_controller.dart",
      "lib/features/wallpapers/presentation/viewer_media.dart",
    ],
    docs: ["docs/video-feed.md", "docs/media-conventions.md §THE video rule"],
  },
  {
    when: ["android/**/wallpaper/**", "lib/features/wallpapers/providers/wallpaper_apply_provider.dart"],
    docs: ["docs/wallpaper-apply.md", "docs/known-issues.md §Traps already paid for"],
  },
  {
    when: ["android/**/MainActivity.kt", "android/app/src/main/AndroidManifest.xml", "android/**/share/**"],
    docs: ["docs/known-issues.md §Traps already paid for", "docs/share.md", "docs/deferred-links.md"],
  },
  {
    when: ["lib/features/wallpapers/**/*share*"],
    docs: ["docs/share.md", "docs/edge-cases.md §Share"],
  },
  {
    when: ["lib/theme/**", "lib/app/theme/**"],
    docs: ["docs/ui-direction.md", ".claude/rules/theming.md"],
  },
  {
    when: ["workers/src/cron/build-catalog.ts", "workers/src/lib/feed-score.ts", "lib/features/wallpapers/**"],
    docs: ["docs/browse.md", "CLAUDE.md §5b Browse Model"],
  },
  {
    when: ["lib/features/ringtones/**"],
    docs: ["docs/ringtones.md", "docs/architecture.md §API"],
  },
  // The hooks are CODE, not prose — CLAUDE.md §8 and release-build/SKILL.md both
  // make claims about what they enforce, so changing one can silently contradict them.
  {
    when: [".claude/hooks/**"],
    docs: ["CLAUDE.md §8 Definition of done & git", ".claude/skills/release-build/SKILL.md"],
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
    // Prose edits ARE the doc update -> a reminder there is noise -> exempt docs/, the READMEs,
    // the tools docs and .claude/{skills,agents,rules}.
    // .claude/hooks/ is deliberately NOT exempt -> it is code CLAUDE.md makes claims about ->
    // suppressing the whole .claude/ tree is how the hooks drifted from those claims.
    if (
      /^(docs\/|CLAUDE\.md$|README\.md$|workers\/README\.md$|tools\/content-import\/.*\.md$|\.claude\/(skills|agents|rules)\/)/i.test(
        rel
      )
    )
      return;

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
