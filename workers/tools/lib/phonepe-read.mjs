/**
 * READ-ONLY PhonePe client for the ops tools. GET status only.
 * There is deliberately no notify, no redeem and no cancel in this file, and none may be added: the
 * tools that import it are run to ANSWER a question about production, and a helper that can move
 * money is one typo away from charging every subscriber. Moving money is `/internal/run-redemptions`,
 * scoped to one merchantSubscriptionId, under OPS_SECRET — see .claude/skills/verify-payments.
 */
import fs from "node:fs";

const HOSTS = {
  PRODUCTION: {
    oauth: "https://api.phonepe.com/apis/identity-manager/v1/oauth/token",
    pg: "https://api.phonepe.com/apis/pg",
  },
  SANDBOX: {
    oauth: "https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token",
    pg: "https://api-preprod.phonepe.com/apis/pg-sandbox",
  },
};

/** The Worker's routing rule (src/lib/phonepe.ts merchantOf): `H` right after `DKS_` = the hsr merchant. */
export const merchantOf = (id) => (String(id).startsWith("DKS_H") ? "hsr" : "legacy");

/**
 * Credentials from real env vars, or from `envFile` (KEY=value lines) when given.
 * Recognised: PP_ENV, PP_CLIENT_ID, PP_CLIENT_SECRET, PP_CLIENT_VERSION (legacy merchant) and
 * PP_HSR_CLIENT_ID, PP_HSR_CLIENT_SECRET, PP_HSR_CLIENT_VERSION (hsr). Either set alone is enough.
 */
export function loadCreds({ envFile } = {}) {
  const src = { ...process.env };
  if (envFile) {
    if (!fs.existsSync(envFile)) {
      console.error(`No such env file: ${envFile}`);
      process.exit(2);
    }
    for (const raw of fs.readFileSync(envFile, "utf8").split("\n")) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const eq = line.indexOf("=");
      if (eq < 0) continue;
      src[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
    }
  }

  const env = (src.PP_ENV || "SANDBOX").trim().toUpperCase();
  if (!HOSTS[env]) {
    console.error(`PP_ENV must be PRODUCTION or SANDBOX, got ${JSON.stringify(env)}`);
    process.exit(2);
  }
  const creds = {
    env,
    merchant: "legacy",
    ...HOSTS[env],
    clientId: (src.PP_CLIENT_ID || "").trim(),
    clientSecret: (src.PP_CLIENT_SECRET || "").trim(),
    clientVersion: (src.PP_CLIENT_VERSION || "1").trim(),
  };
  const hsr = {
    env,
    merchant: "hsr",
    ...HOSTS[env],
    clientId: (src.PP_HSR_CLIENT_ID || "").trim(),
    clientSecret: (src.PP_HSR_CLIENT_SECRET || "").trim(),
    clientVersion: (src.PP_HSR_CLIENT_VERSION || "1").trim(),
  };
  const has = (c) => !!c.clientId && !!c.clientSecret;
  if (!has(creds) && !has(hsr)) {
    console.error(
      "PP_CLIENT_ID + PP_CLIENT_SECRET (legacy) or PP_HSR_CLIENT_ID + PP_HSR_CLIENT_SECRET (hsr) are required " +
        "(env vars or --env-file).",
    );
    process.exit(2);
  }
  return { ...creds, legacy: has(creds) ? creds : null, hsr: has(hsr) ? hsr : null };
}

/** The set that can see `id` -> a merchant only sees its own mandates, so the other set would answer "not found". */
export function credsFor(creds, id) {
  const merchant = merchantOf(id);
  const picked = creds[merchant];
  if (!picked) {
    console.error(`${id} belongs to the ${merchant} merchant, but no ${merchant} credentials were given.`);
    process.exit(2);
  }
  return picked;
}

/** One OAuth token per merchant for the life of the process. */
export function tokenCache() {
  const tokens = {};
  return async (c) => {
    tokens[c.merchant] ??= await getToken(c);
    return tokens[c.merchant];
  };
}

export async function getToken(creds) {
  const res = await fetch(creds.oauth, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: creds.clientId,
      client_secret: creds.clientSecret,
      client_version: creds.clientVersion,
      grant_type: "client_credentials",
    }).toString(),
  });
  const body = await res.text();
  if (!res.ok) {
    throw new Error(`OAuth ${res.status}: ${body.slice(0, 300)}`);
  }
  return JSON.parse(body).access_token;
}

async function get(creds, token, path) {
  const res = await fetch(`${creds.pg}${path}`, {
    headers: { Authorization: `O-Bearer ${token}`, "Content-Type": "application/json" },
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* a non-JSON body is itself the finding — keep the raw text */
  }
  return { status: res.status, text, json };
}

/** Order status. `merchantOrderId` is OURS (the DKS_… string), not PhonePe's OMO… id. */
export const orderStatus = (creds, token, merchantOrderId) =>
  get(creds, token, `/subscriptions/v2/order/${encodeURIComponent(merchantOrderId)}/status?details=true`);

/**
 * Mandate status. Takes the MERCHANT subscription id (DKS_S_… / DKS_HS_…), matching the Worker's
 * getSubscriptionStatus. A mandate the user never authorised answers 400 SUBSCRIPTION_NOT_FOUND —
 * that is success (nothing exists, nothing can debit), not a live orphan.
 */
export const subscriptionStatus = (creds, token, merchantSubscriptionId) =>
  get(creds, token, `/subscriptions/v2/${encodeURIComponent(merchantSubscriptionId)}/status?details=true`);
