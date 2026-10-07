// PostToolUse (Write|Edit): match the edited path against a static table and name the doc that owns
// it. Reminds once per route per session, never blocks. The table IS the maintenance job: keep it in
// step with the .claude/rules/ globs (doc-update skill).
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

// First match wins. Order specific -> general; the catch-all workers/src/lib/** row stays LAST.
const ROUTES = [
  { when: ["lib/features/review/**"], docs: ["docs/review-prompt.md", "docs/edge-cases.md §Review prompt"] },
  {
    when: ["lib/features/app_update/**", "lib/core/update/**", "android/app/src/main/kotlin/**/update/**"],
    docs: ["docs/app-update.md", "docs/edge-cases.md §In-app update"],
  },
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
    docs: ["docs/phonepe.md", "docs/phonepe-webhook.md (webhook handling only)"],
  },
  // The offer's shared transitions and the hourly sweeps outrank the cron, premium and lib catch-all rows.
  {
    when: [
      "workers/src/lib/subscription-state.ts",
      "workers/src/lib/pricing.ts",
      "workers/src/cron/autopay-sweeps.ts",
      "lib/features/premium/presentation/cancel_offer_sheet.dart",
      "lib/features/premium/domain/cancel_offer.dart",
    ],
    docs: [
      "docs/cancel-offer.md",
      "docs/autopay-debits.md §The hourly sweeps",
      "docs/edge-cases.md §Premium / payments",
    ],
  },
  // Push is a cron too, so it must outrank the generic cron row.
  {
    when: [
      "workers/src/cron/push-dispatch.ts",
      "workers/src/lib/fcm.ts",
      "workers/src/lib/push-audience.ts",
      "lib/features/push/**",
      "android/**/push/**",
      "db/schema/17_push.sql",
      "db/schema/31_push_left_out.sql",
    ],
    docs: ["docs/push.md", "docs/push-registry.md", "docs/edge-cases.md §Push"],
  },
  {
    when: ["workers/src/cron/**", "workers/wrangler.toml"],
    docs: ["docs/cron.md", "workers/README.md §Dev / deploy"],
  },
  {
    when: ["workers/src/lib/entitlement.ts", "lib/features/premium/**"],
    docs: [
      "docs/checkout.md",
      "docs/architecture.md §Entitlement",
      "docs/edge-cases.md §Premium / payments",
      "CLAUDE.md §1 Product",
    ],
  },
  {
    when: [
      "workers/src/routes/auth.ts",
      "workers/src/lib/jwt.ts",
      "workers/src/lib/google.ts",
      "lib/features/auth/**",
      "lib/core/auth/**",
    ],
    docs: ["docs/auth.md", "docs/sign-in-wall.md", "docs/architecture.md §Security"],
  },
  {
    when: [
      "workers/src/routes/media.ts",
      "workers/src/lib/r2.ts",
      "workers/src/lib/media-constraints.ts",
      "workers/src/lib/media-verify.ts",
    ],
    docs: [
      "docs/caching.md §Cache-Control written by this repo",
      "docs/media-conventions.md",
      "docs/status-clips.md (status role)",
    ],
  },
  {
    when: ["workers/src/routes/internal.ts", "lib/features/upload/**"],
    docs: ["docs/architecture.md §Uploads", "docs/edge-cases.md §Upload"],
  },
  // The three delivery paths for a target (App Link, Play referrer, Google Ads DDL) share one persisted
  // one-shot in lib/core/deeplink/install_referrer_service.dart.
  {
    when: ["lib/core/deeplink/**", "lib/features/wallpapers/presentation/apply_restore.dart"],
    docs: ["docs/deep-links.md", "docs/share.md §Attribution"],
  },
  // The language precedence and the region ask, ahead of the generic routes row.
  {
    when: [
      "lib/core/providers/locale_provider.dart",
      "lib/core/providers/geo_region_service.dart",
      "workers/src/routes/geo.ts",
    ],
    docs: ["docs/deep-links.md §Language precedence", "workers/README.md §Routes"],
  },
  // Capture stopped; what remains pays out pending rows and serves old builds.
  {
    when: ["workers/src/lib/referral.ts"],
    docs: ["docs/data-model.md §Identity and entitlement", "docs/known-issues.md (referral entry)"],
  },
  { when: ["workers/tools/local-seed-statuses.mjs"], docs: ["docs/local-stack.md", "docs/status-clips.md"] },
  { when: ["workers/tools/local-*.mjs", "workers/tools/local-cdn/**"], docs: ["docs/local-stack.md"] },
  {
    when: ["workers/src/env.ts", "env.example.json"],
    docs: ["workers/README.md §Secrets", "CLAUDE.md §4 Secrets"],
  },
  {
    when: ["workers/src/routes/**", "workers/src/index.ts", "lib/core/api/**"],
    docs: ["docs/architecture.md §API", "workers/README.md"],
  },
  { when: ["db/schema/**", "db/seed.sql"], docs: ["docs/data-model.md", "docs/architecture.md §Schema"] },
  {
    when: [
      "lib/features/quick_bar/**",
      "android/**/quickbar/**",
      "android/app/src/main/res/layout/quick_bar_*",
    ],
    docs: ["docs/quick-bar.md"],
  },
  { when: ["lib/features/notifications/**"], docs: ["docs/notifications.md"] },
  {
    when: ["lib/core/analytics/**", "workers/src/lib/posthog.ts", "workers/src/lib/analytics-context.ts"],
    docs: [
      "docs/analytics-events.md",
      "docs/analytics-signal.md",
      "docs/analytics-ops.md",
      "docs/google-ads.md",
    ],
  },
  // Geometry and the card chrome sit under the reel glob below, so they go first.
  {
    when: ["lib/app/widgets/reel/feed_card_geometry.dart", "lib/app/widgets/reel/reel_card.dart"],
    docs: ["docs/feed-card.md"],
  },
  {
    when: [
      "android/**/feedvideo/**",
      "lib/features/wallpapers/data/**",
      "lib/app/widgets/reel/**",
      "lib/features/wallpapers/presentation/viewer_media.dart",
    ],
    docs: ["docs/video-feed.md", "docs/edge-cases-reel.md", "docs/media-conventions.md §THE video rule"],
  },
  // The shell sequences both reels' decoders and hides the flagged Status tab.
  {
    when: ["lib/app/shell/**"],
    docs: ["docs/video-feed.md §Two reels, one device", "docs/ui-direction.md §Dock"],
  },
  {
    when: ["lib/features/status/**", "android/app/src/main/kotlin/com/hsrutility/arul/status/**"],
    docs: ["docs/status.md", "docs/edge-cases-reel.md §Status tab", "docs/share.md §Status clips"],
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
    when: ["lib/features/share/**", "lib/features/wallpapers/**/*share*"],
    docs: ["docs/share.md", "docs/edge-cases.md §Share"],
  },
  { when: ["lib/theme/**", "lib/app/theme/**"], docs: ["docs/ui-direction.md", ".claude/rules/theming.md"] },
  {
    when: [
      "workers/src/cron/build-catalog.ts",
      "workers/src/lib/feed-score.ts",
      "lib/features/wallpapers/**",
    ],
    docs: ["docs/browse.md", "CLAUDE.md §1 Product"],
  },
  { when: ["lib/features/ringtones/**"], docs: ["docs/ringtones.md", "docs/architecture.md §API"] },
  // The hooks are code that CLAUDE.md §6 and the release-build skill make claims about.
  {
    when: [".claude/hooks/**"],
    docs: ["CLAUDE.md §6 Definition of done and git", ".claude/skills/release-build/SKILL.md"],
  },
  // LAST: a general rule cannot rot as files are added; a list of names does.
  { when: ["workers/src/lib/**"], docs: ["docs/architecture.md", "workers/README.md"] },
];

const REPO_ROOT = process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..", "..");

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
      // biome-ignore lint/suspicious/noTemplateCurlyInString: regex metacharacters, not a template
    } else if (".+^${}()|[]\\?".includes(c)) {
      re += "\\" + c;
    } else {
      re += c;
    }
  }
  return new RegExp("^" + re + "$");
}

// Once per route per session: editing eight files under workers/src/cron/ says "docs/cron.md" once.
function alreadyReminded(sessionId, key) {
  const safe = String(sessionId || "").replace(/[^A-Za-z0-9._-]/g, "");
  if (!safe) return false;
  const f = path.join(os.tmpdir(), `doc-sync-arul-${safe}.txt`);
  try {
    const seen = fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n") : [];
    if (seen.includes(key)) return true;
    fs.appendFileSync(f, key + "\n");
  } catch {
    /* dedupe is best-effort */
  }
  return false;
}

// Prose edits ARE the doc update: docs/, the READMEs, the tools docs and .claude/{skills,agents,rules}
// get no reminder. .claude/hooks/ stays routed — it is code that CLAUDE.md makes claims about.
const EXEMPT =
  /^(docs\/|CLAUDE\.md$|README\.md$|workers\/README\.md$|tools\/content-import\/.*\.md$|\.claude\/(skills|agents|rules)\/)/i;

function post(input) {
  const file = input.tool_input?.file_path || input.tool_response?.filePath || "";
  if (!file || /\.(g|freezed)\.dart$/i.test(file)) return; // generated code carries no documented contract

  let rel = path.isAbsolute(file) ? path.relative(REPO_ROOT, file) : file;
  rel = rel.split(path.sep).join("/").replace(/^\.\//, "");
  if (rel.startsWith("..") || EXEMPT.test(rel)) return;

  const relLower = rel.toLowerCase();
  for (const route of ROUTES) {
    const hit = route.when.find((p) => globToRegExp(p.toLowerCase()).test(relLower));
    if (!hit) continue;
    if (alreadyReminded(input.session_id, hit)) return;
    const msg =
      `[doc-sync] ${hit} changed → ${route.docs.join(", ")}\n` +
      `Update the doc ONLY if a constraint changed: a new trap paid for on device, a changed contract, a dead ` +
      `end worth not repeating. Moved/restyled UI, copy tweaks, refactors, and anything readable from the code ` +
      `or the running app get NO doc update.`;
    return { stdout: { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: msg } } };
  }
}

module.exports = { post, ROUTES };
