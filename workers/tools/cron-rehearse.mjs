/**
 * Run ONE cron locally against the Neon `debug` branch and local KV/R2 — never production.
 *
 *   node tools/cron-rehearse.mjs hourly            # "0 * * * *"   catalog rebuild (+ on-change sweep)
 *   node tools/cron-rehearse.mjs daily             # "30 21 * * *" unconditional sweeps + popularity bump
 *   node tools/cron-rehearse.mjs autopay --allow-autopay   # the quarter-hour trigger, PhonePe SANDBOX only
 *   node tools/cron-rehearse.mjs push --allow-push         # "* * * * *"   campaign push dispatch
 *   node tools/cron-rehearse.mjs hourly --wait 90  # seconds to let ctx.waitUntil work finish (default 60)
 *
 * What keeps this safe, and why each line exists:
 *  - `wrangler dev` (never --remote) -> KV and R2 are the LOCAL simulation -> a sweep can delete nothing real
 *  - the Hyperdrive string in .dev.vars points at the `debug` branch -> every row it touches is a throwaway copy
 *  - POSTHOG_HOST is overridden to an unroutable address -> a server event raised on debug data never reaches
 *    the real project (the API key in .dev.vars is the production key)
 *  - autopay talks to PhonePe -> refused unless .dev.vars says PHONEPE_ENV=SANDBOX AND you pass --allow-autopay
 *  - push REALLY SENDS to whatever phones the debug branch's push_devices holds -> refused unless you pass
 *    --allow-push AND .dev.vars sets PUSH_ENABLED=true. Local KV cannot make an FCM send local: the message
 *    leaves for Google and arrives on a real phone. The debug branch is what keeps that to test phones
 *
 * The scheduled handler answers /__scheduled immediately and does its work in ctx.waitUntil -> this streams
 * the dev-server log for --wait seconds after the trigger so the `[cron] … complete` lines are visible.
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const CRONS = {
  hourly: "0 * * * *",
  daily: "30 21 * * *",
  autopay: "*/15 * * * *",
  push: "* * * * *",
};
const PORT = 8799;

const args = process.argv.slice(2);
const which = args.find((a) => !a.startsWith("--"));
const allowAutopay = args.includes("--allow-autopay");
const allowPush = args.includes("--allow-push");
const waitIdx = args.indexOf("--wait");
const waitSeconds = waitIdx >= 0 ? Number(args[waitIdx + 1]) || 60 : 60;

if (!which || !(which in CRONS)) {
  console.error(`usage: node tools/cron-rehearse.mjs <${Object.keys(CRONS).join("|")}> [--allow-autopay] [--allow-push] [--wait N]`);
  process.exit(2);
}
if (args.includes("--remote") || args.includes("-r")) {
  console.error("REFUSED: --remote would run against PRODUCTION bindings. Rehearsals are local only.");
  process.exit(1);
}

const devVars = fs.readFileSync(new URL("../.dev.vars", import.meta.url), "utf8");
// The debug branch string is handed to wrangler EXPLICITLY through the process environment, under the name
// wrangler 4.1xx reads (`CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_<BINDING>`; the older `WRANGLER_` name
// is silently ignored) -> the rehearsal can never inherit a prod string from a stale .dev.vars line.
const debugUrl = devVars.match(/^DEBUG_DATABASE_URL=\s*"?(postgres(?:ql)?:\/\/[^\s"']+)/m)?.[1] ?? "";
const prodUrl = devVars.match(/^DATABASE_URL=\s*"?(postgres(?:ql)?:\/\/[^\s"']+)/m)?.[1] ?? "";
const hostOf = (u) => u.match(/@([^/\s]+)/)?.[1] ?? "";
const debug = hostOf(debugUrl);
if (!debug) {
  console.error("REFUSED: no DEBUG_DATABASE_URL in .dev.vars — create the debug branch first (neon-migration skill).");
  process.exit(1);
}
if (debug === hostOf(prodUrl)) {
  console.error("REFUSED: DEBUG_DATABASE_URL points at the same host as DATABASE_URL (production).");
  process.exit(1);
}
if (which === "push") {
  // The one rehearsal whose side effect leaves the machine. Nothing local can intercept an FCM send,
  // so the guards are the debug branch (whose push_devices holds only phones you registered against it)
  // and an explicit flag. PUSH_ENABLED gates the dispatcher itself -> without it the rehearsal is a no-op
  // that reads as "the cron did nothing", which is the confusing failure, not the dangerous one.
  const pushEnabled = (devVars.match(/^PUSH_ENABLED=(.*)$/m)?.[1] ?? "").trim().replace(/^"|"$/g, "");
  if (pushEnabled !== "true") {
    console.error(`REFUSED: push rehearsal needs PUSH_ENABLED=true in .dev.vars (found "${pushEnabled || "unset"}").`);
    process.exit(1);
  }
  if (!allowPush) {
    console.error("REFUSED: a push send reaches real phones through Google. Re-run with --allow-push once the debug branch's push_devices holds only test phones.");
    process.exit(1);
  }
}
if (which === "autopay") {
  const phonepeEnv = (devVars.match(/^PHONEPE_ENV=(.*)$/m)?.[1] ?? "").trim();
  if (phonepeEnv !== "SANDBOX") {
    console.error(`REFUSED: autopay rehearsal needs PHONEPE_ENV=SANDBOX in .dev.vars (found "${phonepeEnv || "unset"}").`);
    process.exit(1);
  }
  if (!allowAutopay) {
    console.error("REFUSED: autopay calls PhonePe. Re-run with --allow-autopay if the sandbox creds are what you mean.");
    process.exit(1);
  }
}

const cron = CRONS[which];
console.log(`[rehearse] ${which} = "${cron}" against debug branch host ${debug}, local KV/R2, PostHog blackholed`);

const dev = spawn(
  "npx",
  [
    "wrangler", "dev",
    "--local",
    "--test-scheduled",
    "--port", String(PORT),
    "--var", "POSTHOG_HOST:http://127.0.0.1:9",
  ],
  {
    shell: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE: debugUrl },
  },
);

let ready = false;
const onLine = (chunk) => {
  const text = chunk.toString();
  process.stdout.write(text);
  if (/Ready on http/i.test(text)) ready = true;
};
dev.stdout.on("data", onLine);
dev.stderr.on("data", onLine);

const stop = () => {
  if (process.platform === "win32") spawn("taskkill", ["/pid", String(dev.pid), "/T", "/F"], { shell: true });
  else dev.kill("SIGTERM");
};
process.on("SIGINT", () => { stop(); process.exit(130); });

for (let i = 0; i < 120 && !ready; i++) await sleep(500);
if (!ready) {
  console.error("[rehearse] wrangler dev never became ready — see the log above");
  stop();
  process.exit(1);
}

const url = `http://127.0.0.1:${PORT}/__scheduled?cron=${encodeURIComponent(cron)}`;
console.log(`[rehearse] GET ${url}`);
try {
  const res = await fetch(url);
  console.log(`[rehearse] trigger answered HTTP ${res.status} — waiting ${waitSeconds}s for the handler's background work`);
} catch (err) {
  console.error("[rehearse] trigger failed:", err?.message ?? err);
  stop();
  process.exit(1);
}
await sleep(waitSeconds * 1000);
console.log("[rehearse] done — read the [cron] lines above; nothing above touched production");
stop();
process.exit(0);
