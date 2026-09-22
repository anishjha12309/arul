/**
 * READ-ONLY PhonePe probe. Fetches an OAuth token and GETs order + mandate status.
 * Moves no money: no /notify, no /redeem, no /cancel — only GET status.
 *
 * Credentials come from real env vars OR from `--env-file <path>`, never from argv — a shell records
 * argv in its history and it lands in any transcript. The env-file form exists because the live
 * credentials are NOT in `.dev.vars` (that file holds the SANDBOX set, which is correct for local
 * dev), so a production probe has to supply them; write them to a scratchpad file, probe, delete it.
 *
 *   PP_ENV=PRODUCTION PP_CLIENT_ID=… PP_CLIENT_SECRET=… node tools/phonepe-status.mjs <sub>[,<order>] …
 *   node tools/phonepe-status.mjs --env-file /tmp/pp.env DKS_S_…,DKS_S_…_B338
 *
 * Each argument is `merchantSubscriptionId` or `merchantSubscriptionId,merchantOrderId` — OUR ids,
 * not PhonePe's OMS…/OMO… ones. Exit 0 = every probe answered 2xx.
 */
import { loadCreds, getToken, orderStatus, subscriptionStatus } from "./lib/phonepe-read.mjs";

const argv = process.argv.slice(2);
const fileIdx = argv.indexOf("--env-file");
const envFile = fileIdx >= 0 ? argv[fileIdx + 1] : undefined;
const targets = argv.filter((a, i) => a !== "--env-file" && i !== fileIdx + 1);

if (targets.length === 0) {
  console.error("usage: node tools/phonepe-status.mjs [--env-file <path>] <subId>[,<orderId>] …");
  process.exit(2);
}

const creds = loadCreds({ envFile });
console.log(`env=${creds.env} base=${creds.pg}`);

const token = await getToken(creds);
console.log(`OAuth OK (token len ${token.length})\n`);

let bad = 0;
for (const t of targets) {
  const [subId, orderId] = t.split(",");

  if (orderId) {
    const r = await orderStatus(creds, token, orderId);
    if (r.status >= 300) bad++;
    console.log(`ORDER ${orderId}\n  HTTP ${r.status} ${r.text.slice(0, 900)}`);
  }

  const s = await subscriptionStatus(creds, token, subId);
  if (s.status >= 300) bad++;
  console.log(`SUB   ${subId}\n  HTTP ${s.status} ${s.text.slice(0, 900)}\n`);
}

process.exit(bad > 0 ? 1 : 0);
