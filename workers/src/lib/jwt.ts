/**
 * JWT helpers for Arul's access + refresh token lifecycle. jose ^5, first-party Workers support.
 *
 * Access: HS256, `sub` + a `prm` hint, 60 min. Refresh: HS256, `sub` + `jti`, 60 days, rotating.
 * `prm` is a UI hint and NEVER authoritative -> every gated action re-reads entitlement live from Neon
 * /auth/refresh denylists the old jti and issues a new pair; /auth/logout denylists the presented jti
 * HS256 is safe here only because this Worker is the sole issuer AND verifier -> a third-party audience needs EdDSA
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
 * Both kinds are HS256 under the SAME secret and carry `sub` -> a refresh sent as Bearer verified as an access token
 * That turned a 60-day credential into a 60-day access token -> and revocation became a no-op on every route
 * The denylist is consulted ONLY on /auth/refresh -> a token revoked at logout kept working until its own expiry
 * Verification is deliberately ASYMMETRIC -> a token minted before this has no typ -> rejecting those 401s everyone
 * So reject only an explicitly WRONG typ, and fall back to the structural tell -> only refresh tokens carry `jti`
 */
const TYP_ACCESS = "acc";
const TYP_REFRESH = "ref";

/**
 * Access-token lifetime: 60 minutes, deliberately not 15.
 *
 * Every expiry costs a /auth/refresh -> one KV read plus a KV write that lives the FULL 60-day refresh TTL
 * At 15 min that is ~4 near-permanent denylist entries per user per active hour -> the keyspace grows unbounded
 * Write volume would scale with DAU x session length -> a cost driven by nothing security-relevant
 * The token carries identity ONLY -> a stale one cannot survive a refund, expiry or cancellation
 * The whole cost is revocation latency on a STOLEN access token, <=60m -> refresh revocation stays immediate
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

/** An invalid, expired or wrong-algorithm token THROWS -> there is no falsy return -> callers must catch. */
export async function verifyAccessToken(
  token: string,
  jwtSecret: string,
): Promise<AccessClaims> {
  const { payload } = await jwtVerify(token, secretKey(jwtSecret), {
    algorithms: ["HS256"],
  });
  if (!payload.sub) throw new Error("missing sub claim");
  // Refuse a refresh token presented as an access token -> see TYP_ACCESS
  // `typ` catches newly minted tokens; `jti` catches the typ-less legacy ones -> only refresh has ever carried a jti
  if (payload.typ === TYP_REFRESH || payload.jti) {
    throw new Error("refresh token presented as access token");
  }
  return payload as AccessClaims;
}

/** Signature only — this does NOT consult the KV denylist -> a revoked token verifies here -> callers must claim it. */
export async function verifyRefreshToken(
  token: string,
  jwtSecret: string,
): Promise<RefreshClaims> {
  const { payload } = await jwtVerify(token, secretKey(jwtSecret), {
    algorithms: ["HS256"],
  });
  if (!payload.sub) throw new Error("missing sub claim");
  if (!payload.jti) throw new Error("missing jti claim");
  // Symmetric guard -> a legacy access token is already refused by the missing-jti check above
  if (payload.typ === TYP_ACCESS) {
    throw new Error("access token presented as refresh token");
  }
  return payload as RefreshClaims;
}

// ── KV denylist helpers ──────────────────────────────────────────────────────

const KV_JTI_PREFIX = "jti:";

/** TTL is the token's REMAINING lifetime -> KV expires the entry exactly when the token could no longer be used. */
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

export async function isJtiDenylisted(
  kv: KVNamespace,
  jti: string,
): Promise<boolean> {
  const val = await kv.get(`${KV_JTI_PREFIX}${jti}`);
  return val !== null;
}

/**
 * Reuse-grace window — how long the pair minted from a rotated refresh token stays replayable to that same token.
 *
 * Rotation is one-shot -> any retry of a refresh that already succeeded server-side would 401
 * A client timeout, a dropped mobile connection or a background/foreground race all do exactly that
 * A 401 there signs a paying user out -> replaying the same pair briefly makes the retry a no-op instead
 * Short on purpose -> a genuinely stolen refresh token is used minutes to days later, outside this, and still 401s
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

/**
 * Denylist a refresh jti and report whether THIS caller consumed it. True -> it may issue a new pair.
 *
 * Check-then-act let two concurrent /auth/refresh calls both see "not denylisted" -> one token forked two sessions
 * KV has no compare-and-set -> this is not a mutex -> it is one read-then-write with the WINNER recorded BY VALUE
 * A caller that reads back a different holder id knows it lost -> with the client's single-flight refresh that is enough
 * An attacker racing inside KV's replication lag is NOT defended -> that needs a Durable Object
 */
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

  // Read back -> a write that landed after ours means that caller owns the rotation -> we must not also issue a pair
  const observed = await kv.get(key);
  return observed === holder;
}
