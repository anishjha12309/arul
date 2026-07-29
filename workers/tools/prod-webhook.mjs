/**
 * PhonePe webhook driver (Arul).
 *
 * The webhook moves NO money — it is a state callback. That is why it is safe
 * to exercise against production, while
 * /payments/initiate, notify, redeem and the operator-only /internal/refund and
 * /internal/run-redemptions routes are red-lined: mandates <= Rs 15,000
 * debit with no UPI PIN, so those genuinely move money.
 *
 * The path below is HARDCODED to /payments/webhook. This file cannot be pointed
 * at a money-moving route, whatever arguments it is given — that is the point,
 * and it is the actual boundary behind the `Bash(node tools/prod-webhook.mjs*)`
 * allow-rule. Do not parameterise the path.
 *
 *   node tools/prod-webhook.mjs <event> <merchantSubscriptionId> <orderId> [--prod]
 *
 * Defaults to http://127.0.0.1:8787 (the wrangler dev sandbox). --prod is
 * required, explicitly, to reach api.hsrutility.com — PhonePe delivers Arul
 * webhooks there too: the Pakiza worker's dispatcher forwards DKS_-prefixed
 * orders to arul-api over the service binding (see docs/provisioning.md).
 *
 * Credentials come from workers/.dev.vars and are never printed.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const WEBHOOK_PATH = "/payments/webhook"; // hardcoded on purpose — see header
const LOCAL_BASE = "http://127.0.0.1:8787";
const PROD_BASE = "https://api.hsrutility.com";

const args = process.argv.slice(2);
const useProd = args.includes("--prod");
const [event, msid, orderId] = args.filter((a) => a !== "--prod");

if (!event || !msid || !orderId) {
  console.error(
    "usage: node tools/prod-webhook.mjs <event> <merchantSubscriptionId> <orderId> [--prod]",
  );
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

// Authorization = SHA256(username + ":" + password) hex — payments.ts:300-302.
const auth = createHash("sha256")
  .update(`${vars.PHONEPE_WEBHOOK_USERNAME}:${vars.PHONEPE_WEBHOOK_PASSWORD}`)
  .digest("hex");

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

const base = useProd ? PROD_BASE : LOCAL_BASE;
const t0 = Date.now();
const res = await fetch(`${base}${WEBHOOK_PATH}`, {
  method: "POST",
  headers: { Authorization: auth, "Content-Type": "application/json" },
  body,
});
const text = await res.text();
console.log(
  `${useProd ? "PROD" : "local"} ${WEBHOOK_PATH} event=${event} sub=${msid} -> ` +
    `HTTP ${res.status} in ${Date.now() - t0}ms :: ${text.slice(0, 200)}`,
);
