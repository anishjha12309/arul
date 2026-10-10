/**
 * Post-deploy soak: did live traffic get worse on the new version? Read-only, Cloudflare GraphQL analytics.
 *
 *   node tools/soak-check.mjs --since <deploy ISO time> [--version <id>] [--soak 15]
 *
 * Waits until `since + soak` (+ analytics lag), then compares the window against the 24 h before `since`:
 *   - Worker invocations that threw or exceeded limits (scriptVersion-filtered when --version is given);
 *   - the custom domain's non-404 response mix: Hono turns a caught error into a 500 envelope, which the
 *     Worker counts as a success, so only edge status codes show it.
 * Exit 0 = healthy or too little traffic to judge (said so), 1 = regression, 2 = could not read.
 * Token: CLOUDFLARE_API_TOKEN, else wrangler's OAuth token (refreshed by `wrangler whoami`); never printed.
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";

const HOST = "arul-api.hsrutility.com";
const ZONE = "hsrutility.com";
const SCRIPT = "arul-api";
// Calibrated on 3 days of 15-min buckets (median ~640 requests): the non-404 2xx share never fell more than
// 6.4 points and 5xx never passed 0.13%. 404s are excluded: vulnerability scanners burst them.
const MIN_REQUESTS = 200;
const MAX_THROW_RATE = 0.005;
const MAX_5XX_RATE = 0.01;
const MAX_2XX_DROP = 0.1;
const LAG_MS = 3 * 60e3;

const { values } = parseArgs({
  options: {
    since: { type: "string" },
    version: { type: "string" },
    soak: { type: "string", default: "15" },
  },
});
const since = Date.parse(values.since ?? "");
const soakMs = Number(values.soak) * 60e3;
if (!Number.isFinite(since) || !Number.isFinite(soakMs)) {
  console.error("usage: node tools/soak-check.mjs --since <ISO> [--version <id>] [--soak <minutes>]");
  process.exit(2);
}

const accountId = (readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8").match(
  /^account_id\s*=\s*"([^"]+)"/m,
) || [])[1];

function token() {
  if (process.env.CLOUDFLARE_API_TOKEN) return process.env.CLOUDFLARE_API_TOKEN;
  spawnSync("npx wrangler whoami", { stdio: "ignore", shell: true });
  const files = [
    join(homedir(), "Library", "Preferences", ".wrangler", "config", "default.toml"),
    join(homedir(), ".config", ".wrangler", "config", "default.toml"),
    join(homedir(), ".wrangler", "config", "default.toml"),
  ].filter(Boolean);
  for (const f of files) {
    if (!existsSync(f)) continue;
    const m = readFileSync(f, "utf8").match(/^oauth_token\s*=\s*"([^"]+)"/m);
    if (m) return m[1];
  }
  return null;
}

const wait = since + soakMs + LAG_MS - Date.now();
if (wait > 0) {
  console.log(`[soak] watching live traffic for ${Math.ceil(wait / 60e3)} min`);
  await sleep(wait);
}

const bearer = token();
if (!bearer || !accountId) {
  console.error("[soak] no Cloudflare token or account_id — cannot read analytics");
  process.exit(2);
}
const api = async (path, body) => {
  const res = await fetch(`https://api.cloudflare.com/client/v4/${path}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await res.json();
  if (j.errors?.length) throw new Error(JSON.stringify(j.errors));
  return j;
};

const iso = (t) => new Date(t).toISOString();
const win = { from: iso(since + 60e3), to: iso(since + soakMs) };
const baseline = { from: iso(since - 24 * 3600e3), to: iso(since) };

async function workerCounts(w, version) {
  const v = version ? `, scriptVersion:"${version}"` : "";
  const q = `{ viewer { accounts(filter:{accountTag:"${accountId}"}) { workersInvocationsAdaptive(limit:100, filter:{scriptName:"${SCRIPT}"${v}, datetime_geq:"${w.from}", datetime_leq:"${w.to}"}) { dimensions { status } sum { requests } } } } }`;
  const rows = (await api("graphql", { query: q })).data.viewer.accounts[0].workersInvocationsAdaptive;
  let total = 0;
  let thrown = 0;
  for (const r of rows) {
    total += r.sum.requests;
    if (!["success", "clientDisconnected"].includes(r.dimensions.status)) thrown += r.sum.requests;
  }
  return { total, thrown };
}

async function edgeCounts(zoneTag, w) {
  const q = `{ viewer { zones(filter:{zoneTag:"${zoneTag}"}) { httpRequestsAdaptiveGroups(limit:100, filter:{clientRequestHTTPHost:"${HOST}", datetime_geq:"${w.from}", datetime_leq:"${w.to}"}) { count dimensions { edgeResponseStatus } } } } }`;
  const rows = (await api("graphql", { query: q })).data.viewer.zones[0].httpRequestsAdaptiveGroups;
  const c = { total: 0, ok: 0, s5xx: 0 };
  for (const r of rows) {
    const s = r.dimensions.edgeResponseStatus;
    if (s === 404) continue;
    c.total += r.count;
    if (s >= 200 && s < 300) c.ok += r.count;
    if (s >= 500) c.s5xx += r.count;
  }
  return c;
}

const pct = (n, d) => (d ? `${((100 * n) / d).toFixed(2)}%` : "n/a");
async function verdict() {
  const zoneTag = (await api(`zones?name=${ZONE}`)).result?.[0]?.id;
  if (!zoneTag) throw new Error(`zone ${ZONE} not visible to this token`);
  const [wNew, wBase, eNew, eBase] = await Promise.all([
    workerCounts(win, values.version),
    workerCounts(baseline),
    edgeCounts(zoneTag, win),
    edgeCounts(zoneTag, baseline),
  ]);
  console.log(
    `[soak] worker: ${wNew.total} req, threw ${pct(wNew.thrown, wNew.total)} (24 h before: ${pct(wBase.thrown, wBase.total)})`,
  );
  console.log(
    `[soak] ${HOST}: ${eNew.total} req, 2xx ${pct(eNew.ok, eNew.total)} (was ${pct(eBase.ok, eBase.total)}), ` +
      `5xx ${pct(eNew.s5xx, eNew.total)} (was ${pct(eBase.s5xx, eBase.total)})`,
  );
  if (wNew.total < MIN_REQUESTS && eNew.total < MIN_REQUESTS) {
    console.log(
      `[soak] INCONCLUSIVE: under ${MIN_REQUESTS} requests in the window; re-run later with the same --since`,
    );
    return 0;
  }
  const fails = [];
  const baseThrow = wBase.total ? wBase.thrown / wBase.total : 0;
  if (wNew.total >= MIN_REQUESTS && wNew.thrown / wNew.total > Math.max(MAX_THROW_RATE, 5 * baseThrow))
    fails.push("Worker exceptions above threshold");
  if (eNew.total >= MIN_REQUESTS) {
    const base5xx = eBase.total ? eBase.s5xx / eBase.total : 0;
    if (eNew.s5xx / eNew.total > Math.max(MAX_5XX_RATE, 5 * base5xx)) fails.push("5xx rate above threshold");
    if (eBase.total && eNew.ok / eNew.total < eBase.ok / eBase.total - MAX_2XX_DROP)
      fails.push(`2xx share fell more than ${MAX_2XX_DROP * 100} points`);
  }
  if (fails.length) {
    console.error(`[soak] REGRESSION: ${fails.join("; ")}`);
    return 1;
  }
  console.log("[soak] healthy");
  return 0;
}

process.exitCode = await verdict().catch((e) => {
  console.error(`[soak] could not read analytics: ${e.message}`);
  return 2;
});
