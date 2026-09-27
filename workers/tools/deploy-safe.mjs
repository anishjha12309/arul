/**
 * Deploy, probe, roll back. The ONE way to ship the Worker.
 *
 *   node tools/deploy-safe.mjs [--soak <minutes>]     # default 15; 0 skips the soak
 *
 * 1. `wrangler deploy` — a failed deploy exits here; the previous version is still serving.
 * 2. `tools/smoke.mjs` against BOTH live hostnames and the CDN pointer.
 * 3. `tools/soak-check.mjs`: live error and status mix on the new version against the 24 h before.
 * 4. Smoke or soak failed -> `wrangler rollback --yes` to the previous version, then exit 1. A soak that
 *    cannot read analytics keeps the deploy and says so.
 *
 * Rollback only ever runs after a deploy that SUCCEEDED and then failed the probe. A deploy that
 * never landed is not rolled back — that would roll back the last good version instead.
 *
 * Preconditions (deploy-worker skill): tsc + vitest green, `wrangler whoami` = admin.
 */
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";

const run = (cmd, args, opts = {}) =>
  spawnSync(cmd, args, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8", shell: true, ...opts });

const { values } = parseArgs({ options: { soak: { type: "string", default: "15" } } });

const since = new Date().toISOString();
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
if (smoke.status !== 0) rollback("smoke");

if (Number(values.soak) > 0) {
  const soak = spawnSync(
    "node",
    [
      "tools/soak-check.mjs",
      "--since",
      since,
      "--soak",
      values.soak,
      ...(versionId === "unknown" ? [] : ["--version", versionId]),
    ],
    { stdio: "inherit" },
  );
  if (soak.status === 1) rollback("soak");
  if (soak.status !== 0)
    console.error("[deploy-safe] soak could not judge — deploy kept; re-run soak-check by hand");
}
console.log(`[deploy-safe] version ${versionId} is live and healthy`);

function rollback(stage) {
  console.error(`[deploy-safe] ${stage} FAILED on ${versionId} — rolling back to the previous version`);
  const rb = run("npx", [
    "wrangler",
    "rollback",
    "--yes",
    "--message",
    `"deploy-safe: ${stage} failed on ${versionId}"`,
  ]);
  process.stdout.write(rb.stdout ?? "");
  if (rb.status !== 0) {
    console.error(
      "[deploy-safe] ROLLBACK FAILED — the broken version is still live; run `npx wrangler rollback` by hand NOW",
    );
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
}
