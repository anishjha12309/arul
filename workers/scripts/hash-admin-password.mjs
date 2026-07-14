#!/usr/bin/env node
/**
 * Generate ADMIN_PASSWORD_HASH for the Arul CMS.
 *
 *   node scripts/hash-admin-password.mjs '<your-password>'
 *
 * Copy the printed line, then store it as a Worker secret:
 *   npx wrangler secret put ADMIN_PASSWORD_HASH      (paste the value)
 *
 * Also set:
 *   npx wrangler secret put ADMIN_USERNAME
 *   npx wrangler secret put ADMIN_SESSION_SECRET     (e.g. `openssl rand -base64 32`)
 *
 * The digest is PBKDF2-HMAC-SHA256 with a random 16-byte salt. The Worker
 * recomputes it on login using the iteration count embedded in the string,
 * so this stays compatible if the iteration count is tuned later.
 */

import { webcrypto as crypto } from "node:crypto";

// Cloudflare Workers' production Web Crypto caps PBKDF2 at 100000 iterations
// (local workerd does NOT enforce this, so a higher value passes `wrangler dev`
// but throws NotSupportedError once deployed). 100000 is the platform max.
const ITERATIONS = 100000;
const KEY_LEN = 32;

const password = process.argv[2];
if (!password) {
  console.error("usage: node scripts/hash-admin-password.mjs '<password>'");
  process.exit(1);
}
if (password.length < 10) {
  console.error("refusing: choose a password of at least 10 characters.");
  process.exit(1);
}

const salt = crypto.getRandomValues(new Uint8Array(16));
const key = await crypto.subtle.importKey(
  "raw",
  new TextEncoder().encode(password),
  "PBKDF2",
  false,
  ["deriveBits"],
);
const bits = new Uint8Array(
  await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: ITERATIONS, hash: "SHA-256" },
    key,
    KEY_LEN * 8,
  ),
);

const b64 = (u) => Buffer.from(u).toString("base64");
console.log(`pbkdf2$${ITERATIONS}$${b64(salt)}$${b64(bits)}`);
