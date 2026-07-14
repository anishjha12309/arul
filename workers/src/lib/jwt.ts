/**
 * JWT helpers for Arul's access + refresh token lifecycle.
 *
 * Uses jose ^5 — first-party support for Cloudflare Workers runtime:
 *   https://github.com/panva/jose
 *
 * Design:
 *   - Access token:  HS256, sub + prm hint, 15-minute TTL.
 *     "prm" is a non-authoritative boolean hint for client-side UI only.
 *     Entitlement is ALWAYS read live from Neon on gated actions.
 *   - Refresh token: HS256, sub + jti (UUID v4), 60-day TTL (rotating).
 *     On /auth/refresh: old jti is added to the KV denylist; a new pair is issued.
 *     On /auth/logout:  refresh jti is added to the KV denylist.
 *   - KV denylist key: "jti:<jti>" → "1", TTL = token remaining lifetime.
 *
 * Using HS256 with a strong random secret (32+ bytes) is appropriate here
 * because the Worker is the only issuer and the only verifier — there is no
 * third-party audience. If multi-issuer support is needed later, migrate to EdDSA.
 */

import { SignJWT, jwtVerify, type JWTPayload } from "jose";

// ── Types ────────────────────────────────────────────────────────────────────

export interface AccessClaims extends JWTPayload {
  sub: string;
  /** Non-authoritative premium hint for client-side UI only. */
  prm?: boolean;
}

export interface RefreshClaims extends JWTPayload {
  sub: string;
  /** UUID v4 used as the jti for denylist tracking. */
  jti: string;
}

const ACCESS_TTL_SECONDS = 15 * 60; // 15 minutes
const REFRESH_TTL_SECONDS = 60 * 24 * 60 * 60; // 60 days

// ── Key derivation ───────────────────────────────────────────────────────────

function secretKey(secret: string): Uint8Array {
  return new TextEncoder().encode(secret);
}

// ── Token issuing ────────────────────────────────────────────────────────────

/** Issue a short-lived access token. */
export async function signAccessToken(
  sub: string,
  jwtSecret: string,
  prmHint?: boolean,
): Promise<string> {
  const builder = new SignJWT({ sub, ...(prmHint !== undefined ? { prm: prmHint } : {}) })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TTL_SECONDS}s`);

  return builder.sign(secretKey(jwtSecret));
}

/** Issue a long-lived refresh token with a unique jti for denylist tracking. */
export async function signRefreshToken(
  sub: string,
  jwtSecret: string,
): Promise<{ token: string; jti: string }> {
  const jti = crypto.randomUUID();
  const token = await new SignJWT({ sub, jti })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${REFRESH_TTL_SECONDS}s`)
    .sign(secretKey(jwtSecret));

  return { token, jti };
}

// ── Token verification ───────────────────────────────────────────────────────

/**
 * Verify and decode an access token.
 * Throws if the token is invalid, expired, or wrong algorithm.
 */
export async function verifyAccessToken(
  token: string,
  jwtSecret: string,
): Promise<AccessClaims> {
  const { payload } = await jwtVerify(token, secretKey(jwtSecret), {
    algorithms: ["HS256"],
  });
  if (!payload.sub) throw new Error("missing sub claim");
  return payload as AccessClaims;
}

/**
 * Verify and decode a refresh token.
 * Does NOT check the KV denylist — callers must do that separately.
 */
export async function verifyRefreshToken(
  token: string,
  jwtSecret: string,
): Promise<RefreshClaims> {
  const { payload } = await jwtVerify(token, secretKey(jwtSecret), {
    algorithms: ["HS256"],
  });
  if (!payload.sub) throw new Error("missing sub claim");
  if (!payload.jti) throw new Error("missing jti claim");
  return payload as RefreshClaims;
}

// ── KV denylist helpers ──────────────────────────────────────────────────────

const KV_JTI_PREFIX = "jti:";

/**
 * Add a refresh token's jti to the KV denylist.
 * TTL is set to the token's remaining lifetime so KV auto-expires the entry.
 * @param kv       Workers KV namespace
 * @param jti      The jti claim value
 * @param expEpoch Token expiry as Unix epoch seconds (from JWT `exp` claim)
 */
export async function denylistJti(
  kv: KVNamespace,
  jti: string,
  expEpoch: number,
): Promise<void> {
  const ttlSeconds = Math.max(60, expEpoch - Math.floor(Date.now() / 1000));
  await kv.put(`${KV_JTI_PREFIX}${jti}`, "1", {
    expirationTtl: ttlSeconds,
  });
}

/** Returns true if the jti is in the denylist (token was revoked). */
export async function isJtiDenylisted(
  kv: KVNamespace,
  jti: string,
): Promise<boolean> {
  const val = await kv.get(`${KV_JTI_PREFIX}${jti}`);
  return val !== null;
}
