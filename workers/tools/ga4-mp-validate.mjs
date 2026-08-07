/**
 * Validate the GA4 Measurement Protocol wiring WITHOUT sending a real event.
 *
 * /mp/collect answers 204 even for payloads it silently drops (wrong
 * api_secret included) — the ONLY endpoint that reports what is wrong is
 * /debug/mp/collect, which validates and returns messages instead of
 * recording. This sends the exact purchase shape lib/ga4.ts sends.
 *
 *   node tools/ga4-mp-validate.mjs <app_instance_id> [transaction_id]
 *
 * Reads GA4_API_SECRET + GA4_FIREBASE_APP_ID from workers/.dev.vars.
 * Empty validationMessages = the payload would be accepted for real.
 * A real device's app_instance_id comes from GA4 DebugView (device row) or
 * `SELECT app_instance_id FROM users …` via tools/prod-query.mjs.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const devVars = fs.readFileSync(path.join(here, "..", ".dev.vars"), "utf8");
const readVar = (name) => {
  const m = devVars.match(new RegExp(`^${name}\\s*=\\s*"?([^"\\r\\n]+)"?`, "m"));
  return m ? m[1].trim() : null;
};

const apiSecret = readVar("GA4_API_SECRET");
const appId = readVar("GA4_FIREBASE_APP_ID");
if (!apiSecret || !appId) {
  console.error("GA4_API_SECRET / GA4_FIREBASE_APP_ID missing from workers/.dev.vars");
  process.exit(2);
}

const appInstanceId = process.argv[2];
if (!/^[a-f0-9]{32}$/.test(appInstanceId ?? "")) {
  console.error("usage: node tools/ga4-mp-validate.mjs <32-hex app_instance_id> [transaction_id]");
  process.exit(2);
}
const transactionId = process.argv[3] ?? "DKS_VALIDATE_ONLY";

const url =
  `https://www.google-analytics.com/debug/mp/collect` +
  `?firebase_app_id=${encodeURIComponent(appId)}&api_secret=${encodeURIComponent(apiSecret)}`;

const res = await fetch(url, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    app_instance_id: appInstanceId,
    events: [
      {
        name: "purchase",
        params: { currency: "INR", value: 199, transaction_id: transactionId },
      },
    ],
  }),
});

const body = await res.json();
console.log(`HTTP ${res.status}`);
console.log(JSON.stringify(body, null, 2));
const messages = body.validationMessages ?? [];
console.log(messages.length === 0 ? "VALID — payload would be accepted" : "INVALID — see messages above");
process.exit(messages.length === 0 ? 0 : 1);
