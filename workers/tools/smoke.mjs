/**
 * Post-deploy smoke probe for the LIVE Worker. Read-only, unauthenticated, no secrets.
 *
 * Exit 0 = every probe answered the way a healthy deploy answers. Exit 1 = something is wrong and
 * the deploy should be rolled back (tools/deploy-safe.mjs does that automatically).
 *
 * Probes both hostnames — the custom domain wrangler owns AND the workers.dev host every
 * already-installed build still calls (deploy-worker skill §4). A deploy that breaks either is a
 * broken deploy.
 *
 *   node tools/smoke.mjs            # human-readable, one line per probe
 */
import { setTimeout as sleep } from "node:timers/promises";

const HOSTS = [
  "https://arul-api.hsrutility.com",
  "https://arul-api.twilight-smoke-d495.workers.dev",
];
const CDN = "https://arul-cdn.hsrutility.com";

/** Each probe: a URL, the status the healthy deploy returns, and a check on the JSON body. */
const probes = [];
for (const host of HOSTS) {
  // The 404 envelope proves the Hono app is up and routing — a platform error page is not JSON.
  probes.push({
    name: `${host} 404 envelope`,
    url: `${host}/nonexistent-smoke-probe`,
    status: 404,
    body: (j) => j && typeof j === "object" && "error" in j,
  });
  // An unauthenticated /me must be a clean 401 — a 500 here means auth or the DB path is broken.
  probes.push({
    name: `${host} /me unauthenticated`,
    url: `${host}/me`,
    status: 401,
    body: (j) => j && typeof j === "object" && "error" in j,
  });
  // The region hint every fresh install reads once -> values depend on where the probe runs -> keys only.
  probes.push({
    name: `${host} /geo`,
    url: `${host}/geo`,
    status: 200,
    body: (j) =>
      j && typeof j === "object" && ["country", "region", "lang"].every((k) => k in j),
  });
}
// The catalog pointer is what every install reads first — must be JSON with a built_at.
probes.push({
  name: `${CDN} catalog pointer`,
  url: `${CDN}/catalog/version.json`,
  status: 200,
  body: (j) => j && typeof j === "object" && typeof j.built_at === "string",
});

async function probe(p, attempt = 1) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 10_000);
  try {
    const res = await fetch(p.url, { signal: ctrl.signal, headers: { "user-agent": "arul-smoke" } });
    let json = null;
    try {
      json = await res.json();
    } catch {
      json = null;
    }
    const ok = res.status === p.status && p.body(json);
    return { ok, detail: `HTTP ${res.status}${json ? "" : " (non-JSON body)"}` };
  } catch (err) {
    // One retry covers a cold edge or a transient reset — a second failure is real.
    if (attempt < 2) {
      await sleep(1500);
      return probe(p, attempt + 1);
    }
    return { ok: false, detail: String(err?.message ?? err) };
  } finally {
    clearTimeout(t);
  }
}

let failed = 0;
for (const p of probes) {
  const r = await probe(p);
  console.log(`${r.ok ? "PASS" : "FAIL"}  ${p.name}  ${r.detail}`);
  if (!r.ok) failed++;
}
if (failed > 0) {
  console.error(`[smoke] ${failed} of ${probes.length} probes FAILED`);
  process.exit(1);
}
console.log(`[smoke] all ${probes.length} probes passed`);
