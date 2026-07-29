/**
 * JWT helpers for Arul's access + refresh token lifecycle.
 *
 * Uses jose ^5 — first-party support for Cloudflare Workers runtime:
 *   https://github.com/panva/jose
 *
 * Design:
 *   - Access token:  HS256, sub + prm hint, 60-minute TTL (see ACCESS_TTL_SECONDS).
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

/**
 * Token-kind marker — the fix for access/refresh type confusion.
 *
 * Both kinds are HS256 signed with the SAME secret and both carry `sub`, so
 * before this claim existed a REFRESH token presented as `Authorization:
 * Bearer <refresh>` verified cleanly as an access token. That turned a 60-day
 * credential into a 60-day access token AND made revocation a no-op: the KV
 * denylist is only consulted on /auth/refresh, so a token revoked at logout
 * kept working on every other route until its own 60-day expiry.
 *
 * Verification is deliberately asymmetric so no existing session is signed out:
 * a token minted before this shipped has NO typ, and rejecting those would 401
 * every live user at once. Instead we reject only a token whose typ is
 * explicitly WRONG, and — for the legacy, typ-less case — fall back to the
 * structural tell that has always been there: refresh tokens carry `jti`,
 * access tokens never have. Both old and new tokens are therefore covered,
 * with zero forced re-authentication.
 */
const TYP_ACCESS = "acc";
const TYP_REFRESH = "ref";

/**
 * Access-token lifetime.
 *
 * 60 minutes, not 15. Every expiry costs a /auth/refresh round trip, and each
 * refresh is a KV READ (denylist check) plus a KV WRITE whose entry then lives
 * for the FULL 60-day refresh TTL. At 15 minutes that is ~4 permanent-ish KV
 * entries per user per active hour — the denylist keyspace grows without bound
 * and the write volume scales with DAU × session length rather than with
 * anything security-relevant.
 *
 * The security cost of the longer window is small and bounded: the access token
 * carries identity ONLY (`sub`) — never entitlement (CLAUDE.md §3) — so a stale
 * token cannot preserve premium after a refund, expiry, or cancellation. Every
 * gated action re-reads entitlement live from Neon. Revocation latency for a
 * stolen ACCESS token rises from ≤15m to ≤60m; refresh-token revocation is
 * unchanged (immediate, via the denylist).
 */
const ACCESS_TTL_SECONDS = 60 * 60; // 60 minutes
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
  const builder = new SignJWT({
    sub,
    typ: TYP_ACCESS,
    ...(prmHint !== undefined ? { prm: prmHint } : {}),
  })
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
  const token = await new SignJWT({ sub, jti, typ: TYP_REFRESH })
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
  // Refuse a refresh token presented as an access token — see TYP_ACCESS.
  // `typ` catches tokens minted after this shipped; `jti` catches the legacy
  // ones that predate it (only refresh tokens have ever carried a jti).
  if (payload.typ === TYP_REFRESH || payload.jti) {
    throw new Error("refresh token presented as access token");
  }
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
  // Symmetric guard. Legacy access tokens are already rejected above (they have
  // never carried a jti); this covers the post-typ ones explicitly.
  if (payload.typ === TYP_ACCESS) {
    throw new Error("access token presented as refresh token");
  }
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

/**
 * Claim a refresh token for rotation: denylist its jti and report whether THIS
 * caller was the one that consumed it.
 *
 * Rotation was previously check-then-act (`isJtiDenylisted` then `denylistJti`),
 * so two concurrent /auth/refresh calls carrying the same refresh token both
 * observed "not denylisted" and both minted a fresh token pair — one refresh
 * token silently forking into two live sessions.
 *
 * KV has no compare-and-set, so this cannot be a true mutex. What it does give
 * is a single read-then-write per caller with the WINNER recorded by value: the
 * first writer's holder id is what lands, and a caller that reads back a
 * different holder knows it lost. Combined with the client's own single-flight
 * refresh, that closes the realistic double-rotation window. A determined
 * attacker racing inside KV's replication lag is not defended here — that needs
 * a Durable Object, which is the documented upgrade path if refresh-token
 * theft ever becomes a real threat model.
 *
 * @returns true when this caller won the rotation and may issue a new pair.
 */
/**
 * Reuse-grace window: how long the pair minted from a given refresh token stays
 * replayable to a caller presenting that same (now-rotated) token.
 *
 * WHY this exists: rotation is one-shot, so ANY retry of a refresh that already
 * succeeded server-side — a client that timed out waiting for the response, a
 * dropped mobile connection mid-flight, a background/foreground race — would
 * otherwise get 401 and the app would sign a paying user out. Replaying the
 * same pair for a short window turns that into a no-op instead of a logout.
 *
 * The window is short on purpose: a genuinely stolen refresh token is used
 * minutes-to-days later, well outside this, and still gets 401. This is the
 * standard refresh-token reuse-grace pattern.
 */
const ROTATION_REPLAY_TTL_SECONDS = 120;
const KV_ROTATION_PREFIX = "rot:";

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
}

/** Remember the pair minted from `oldJti` so a retry of that refresh replays it. */
export async function storeRotationReplay(
  kv: KVNamespace,
  oldJti: string,
  pair: TokenPair,
): Promise<void> {
  await kv.put(`${KV_ROTATION_PREFIX}${oldJti}`, JSON.stringify(pair), {
    expirationTtl: ROTATION_REPLAY_TTL_SECONDS,
  });
}

/** The pair previously minted from `oldJti`, if still inside the grace window. */
export async function readRotationReplay(
  kv: KVNamespace,
  oldJti: string,
): Promise<TokenPair | null> {
  const raw = await kv.get(`${KV_ROTATION_PREFIX}${oldJti}`, "json");
  if (!raw) return null;
  const pair = raw as Partial<TokenPair>;
  return typeof pair.accessToken === "string" && typeof pair.refreshToken === "string"
    ? { accessToken: pair.accessToken, refreshToken: pair.refreshToken }
    : null;
}

export async function claimRefreshJti(
  kv: KVNamespace,
  jti: string,
  expEpoch: number,
): Promise<boolean> {
  const key = `${KV_JTI_PREFIX}${jti}`;
  const existing = await kv.get(key);
  if (existing !== null) return false; // already rotated or revoked

  const holder = crypto.randomUUID();
  const ttlSeconds = Math.max(60, expEpoch - Math.floor(Date.now() / 1000));
  await kv.put(key, holder, { expirationTtl: ttlSeconds });

  // Read back: if another caller's write landed after ours, they own the
  // rotation and we must not also issue a pair.
  const observed = await kv.get(key);
  return observed === holder;
}
