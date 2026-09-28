/**
 * PhonePe webhook driver (Arul).
 * The path below is HARDCODED to /payments/webhook. This file cannot be pointed
 * at a money-moving route, whatever arguments it is given — that is the point,
 * and it is the actual boundary behind the `Bash(node tools/prod-webhook.mjs*)`
 * allow-rule. Do not parameterise the path.
 *   node tools/prod-webhook.mjs <event> <merchantSubscriptionId> <orderId> [--prod] [--hsr]
 * --hsr signs with the HSRUTILITYONLINE pair (PHONEPE_HSR_WEBHOOK_*) and, with --prod, posts to arul-api directly —
 * the URL that merchant's dashboard webhook names. Without it: the legacy pair through the hsr-cms dispatcher.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const WEBHOOK_PATH = "/payments/webhook"; // hardcoded on purpose — see header
const LOCAL_BASE = "http://127.0.0.1:8787";
const PROD_BASE = "https://api.hsrutility.com";
const PROD_BASE_HSR = "https://arul-api.hsrutility.com";

const args = process.argv.slice(2);
const useProd = args.includes("--prod");
const useHsr = args.includes("--hsr");
const [event, msid, orderId] = args.filter((a) => a !== "--prod" && a !== "--hsr");

if (!event || !msid || !orderId) {
  console.error("usage: node tools/prod-webhook.mjs <event> <merchantSubscriptionId> <orderId> [--prod]");
  process.exit(2);
}

// The dispatcher only forwards DKS_ ids to arul-api (cross-app guard); fail
// here too so a typo never reaches production at all.
if (!msid.startsWith("DKS_")) {
  console.error("REFUSED: merchantSubscriptionId must start with DKS_ (Arul's prefix).");
  process.exit(1);
}

const vars = Object.fromEntries(
  readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
    .split(/\r?\n/)
    .filter((l) => l && !l.trimStart().startsWith("#") && l.includes("="))
    .map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
    }),
);

const pair = useHsr
  ? [vars.PHONEPE_HSR_WEBHOOK_USERNAME, vars.PHONEPE_HSR_WEBHOOK_PASSWORD]
  : [vars.PHONEPE_WEBHOOK_USERNAME, vars.PHONEPE_WEBHOOK_PASSWORD];
if (!pair[0] || !pair[1]) {
  console.error(
    `the ${useHsr ? "PHONEPE_HSR_WEBHOOK_*" : "PHONEPE_WEBHOOK_*"} pair is missing from .dev.vars`,
  );
  process.exit(2);
}
const auth = createHash("sha256").update(`${pair[0]}:${pair[1]}`).digest("hex");

const body = JSON.stringify({
  event,
  payload: {
    merchantSubscriptionId: msid,
    merchantOrderId: `${msid}_WH`,
    orderId,
    state: "COMPLETED",
    amount: 19900,
    subscriptionId: "PPSUB_TOOL_1",
    paymentDetails: [{ transactionId: "TXN_TOOL_1", state: "COMPLETED", amount: 19900 }],
  },
});

const base = useProd ? (useHsr ? PROD_BASE_HSR : PROD_BASE) : LOCAL_BASE;
const t0 = Date.now();
const res = await fetch(`${base}${WEBHOOK_PATH}`, {
  method: "POST",
  headers: { Authorization: auth, "Content-Type": "application/json" },
  body,
});
const text = await res.text();
console.log(
  `${useProd ? "PROD" : "local"} ${WEBHOOK_PATH} pair=${useHsr ? "hsr" : "legacy"} event=${event} sub=${msid} -> ` +
    `HTTP ${res.status} in ${Date.now() - t0}ms :: ${text.slice(0, 200)}`,
);
