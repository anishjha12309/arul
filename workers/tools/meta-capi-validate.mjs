/**
 * Validate the Meta Conversions API wiring WITHOUT polluting the real dataset.
 *
 * Sends the EXACT system_generated Subscribe shape lib/meta.ts sends, plus a
 * test_event_code — Meta then routes it to Events Manager → Test Events only
 * (visible there for manual confirmation, never counted in the dataset or used
 * for ads). Graph answers 200 + {"events_received":N} on acceptance, or a 4xx
 * with an error object naming what is wrong (bad token, bad dataset id,
 * rejected extinfo, …).
 *
 *   node tools/meta-capi-validate.mjs <test_event_code> [email]
 *
 * Reads META_DATASET_ID + META_CAPI_ACCESS_TOKEN from workers/.dev.vars.
 * The test_event_code comes from Events Manager → the dataset → Test Events.
 * email defaults to a placeholder (hashed before sending, like production).
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const devVars = fs.readFileSync(path.join(here, "..", ".dev.vars"), "utf8");
const readVar = (name) => {
  const m = devVars.match(new RegExp(`^${name}\\s*=\\s*"?([^"\\r\\n]+)"?`, "m"));
  return m ? m[1].trim() : null;
};

const datasetId = readVar("META_DATASET_ID");
const accessToken = readVar("META_CAPI_ACCESS_TOKEN");
if (!datasetId || !accessToken) {
  console.error("META_DATASET_ID / META_CAPI_ACCESS_TOKEN missing from workers/.dev.vars");
  process.exit(2);
}

const testEventCode = process.argv[2];
if (!testEventCode) {
  console.error("usage: node tools/meta-capi-validate.mjs <test_event_code> [email]");
  process.exit(2);
}
const email = (process.argv[3] ?? "validate-only@example.com").trim().toLowerCase();

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const txn = `DKS_VALIDATE_${Date.now()}`;

const userData = {
  em: [sha256(email)],
  external_id: [sha256("00000000-0000-0000-0000-000000000000")],
};

const res = await fetch(
  `https://graph.facebook.com/v25.0/${encodeURIComponent(datasetId)}/events` +
  `?access_token=${encodeURIComponent(accessToken)}`,
  {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      test_event_code: testEventCode,
      data: [
        {
          event_name: "Subscribe",
          event_time: Math.floor(Date.now() / 1000),
          event_id: txn,
          action_source: "system_generated",
          user_data: userData,
          custom_data: { currency: "INR", value: 199, order_id: txn },
        },
      ],
    }),
  },
);

const body = await res.text();
console.log(`HTTP ${res.status}`);
console.log(body);
let ok = false;
try {
  ok = res.ok && (JSON.parse(body).events_received ?? 0) >= 1;
} catch { /* non-JSON body — leave ok false */ }
console.log(
  ok
    ? `ACCEPTED — check Events Manager → Test Events for Subscribe (event_id ${txn})`
    : "REJECTED — see response above",
);
process.exit(ok ? 0 : 1);
