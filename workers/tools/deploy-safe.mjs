/**
 * Deploy, probe, roll back. The ONE way to ship the Worker.
 *
 *   node tools/deploy-safe.mjs
 *
 * 1. `wrangler deploy` — a failed deploy exits here; the previous version is still serving.
 * 2. `tools/smoke.mjs` against BOTH live hostnames and the CDN pointer.
 * 3. Smoke failed -> `wrangler rollback --yes` to the previous version, then exit 1.
 *
 * Rollback only ever runs after a deploy that SUCCEEDED and then failed the probe. A deploy that
 * never landed is not rolled back — that would roll back the last good version instead.
 *
 * Preconditions (deploy-worker skill): tsc + vitest green, `wrangler whoami` = admin.
 */
import { spawnSync } from "node:child_process";

const run = (cmd, args, opts = {}) =>
  spawnSync(cmd, args, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8", shell: true, ...opts });

console.log("[deploy-safe] wrangler deploy");
const deploy = run("npx", ["wrangler", "deploy"]);
process.stdout.write(deploy.stdout ?? "");
if (deploy.status !== 0) {
  console.error("[deploy-safe] deploy FAILED — nothing changed on Cloudflare, no rollback needed");
  process.exit(deploy.status ?? 1);
}
const versionId = (deploy.stdout.match(/Current Version ID:\s*([0-9a-f-]+)/i) || [])[1] ?? "unknown";
console.log(`[deploy-safe] deployed version ${versionId} — probing`);

const smoke = run("node", ["tools/smoke.mjs"]);
process.stdout.write(smoke.stdout ?? "");
if (smoke.status === 0) {
  console.log(`[deploy-safe] version ${versionId} is live and healthy`);
  process.exit(0);
}

console.error(`[deploy-safe] smoke FAILED on ${versionId} — rolling back to the previous version`);
const rollback = run("npx", [
  "wrangler",
  "rollback",
  "--yes",
  "--message",
  `"deploy-safe: smoke failed on ${versionId}"`,
]);
process.stdout.write(rollback.stdout ?? "");
if (rollback.status !== 0) {
  console.error("[deploy-safe] ROLLBACK FAILED — the broken version is still live; run `npx wrangler rollback` by hand NOW");
  process.exit(2);
}
// Prove the rollback restored service — a rollback that also fails the probe is a platform problem, not ours.
const recheck = run("node", ["tools/smoke.mjs"]);
process.stdout.write(recheck.stdout ?? "");
console.error(
  recheck.status === 0
    ? "[deploy-safe] rolled back; previous version healthy again. Fix the change and redeploy."
    : "[deploy-safe] rolled back but the probe STILL fails — the failure predates this deploy; investigate before redeploying",
);
process.exit(1);
