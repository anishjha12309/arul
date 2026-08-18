/**
 * READ-ONLY PhonePe probe. Fetches an OAuth token and GETs order + subscription
 * status. Moves no money: no /notify, no /redeem, no /cancel — only GET status.
 *
 * Credentials come from the environment (PP_CLIENT_ID / PP_CLIENT_SECRET /
 * PP_CLIENT_VERSION / PP_ENV) so nothing is written to disk.
 */
const ENV = (process.env.PP_ENV || "SANDBOX").trim().toUpperCase();
const isProd = ENV === "PRODUCTION";

const OAUTH = isProd
  ? "https://api.phonepe.com/apis/identity-manager/v1/oauth/token"
  : "https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token";
const BASE = isProd
  ? "https://api.phonepe.com/apis/pg"
  : "https://api-preprod.phonepe.com/apis/pg-sandbox";

console.log(`env=${ENV} base=${BASE}`);

const form = new URLSearchParams({
  client_id: (process.env.PP_CLIENT_ID || "").trim(),
  client_secret: (process.env.PP_CLIENT_SECRET || "").trim(),
  client_version: (process.env.PP_CLIENT_VERSION || "1").trim(),
  grant_type: "client_credentials",
});

const tokRes = await fetch(OAUTH, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: form.toString(),
});
const tokBody = await tokRes.text();
if (!tokRes.ok) {
  console.error(`OAuth FAILED ${tokRes.status}: ${tokBody.slice(0, 500)}`);
  process.exit(1);
}
const token = JSON.parse(tokBody).access_token;
console.log(`OAuth OK (token len ${token.length})\n`);

for (const t of process.argv.slice(2)) {
  const [subId, orderId] = t.split(",");

  if (orderId) {
    const r = await fetch(
      `${BASE}/subscriptions/v2/order/${encodeURIComponent(orderId)}/status?details=true`,
      { headers: { Authorization: `O-Bearer ${token}`, "Content-Type": "application/json" } },
    );
    console.log(`ORDER ${orderId}\n  HTTP ${r.status} ${(await r.text()).slice(0, 900)}`);
  }

  const s = await fetch(
    `${BASE}/subscriptions/v2/${encodeURIComponent(subId)}/status?details=true`,
    { headers: { Authorization: `O-Bearer ${token}`, "Content-Type": "application/json" } },
  );
  console.log(`SUB   ${subId}\n  HTTP ${s.status} ${(await s.text()).slice(0, 900)}\n`);
}
