/**
 * Spec: https://developers.google.com/identity/sign-in/web/backend-auth · JWKS: /oauth2/v3/certs
 * `aud` is the WEB client id, never the Android one -> an Android-audience token is a different app's token
 * Google issues both bare and https `accounts.google.com` -> accept both issuers or half the tokens fail
 * The `nonce` claim is RETURNED, not checked -> only the caller knows what it asked for -> handleLogin compares
 * jose's createRemoteJWKSet ignores Cache-Control (fixed 10 min) and lives per isolate -> the keys are fetched here
 */

import { jwtVerify, createLocalJWKSet, errors } from "jose";
import type { JSONWebKeySet } from "jose";

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const VALID_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];

// A hung googleapis socket must not eat the app's 15 s login budget -> fail fast as keys-unavailable
const JWKS_FETCH_TIMEOUT_MS = 3_000;
// Google's max-age runs ~5-7 h and rotated keys overlap it -> cap at 6 h, floor at 1 min
const JWKS_MAX_TTL_S = 6 * 60 * 60;
const JWKS_MIN_TTL_S = 60;
const JWKS_DEFAULT_TTL_S = 10 * 60;
// A token naming an unknown `kid` forces a refetch -> a junk kid must not buy a Google fetch per request
const KID_MISS_COOLDOWN_MS = 30_000;
const STALE_KEYS_MAX_MS = 24 * 60 * 60 * 1000;
// Cache API entries carry our own absolute expiry -> the in-memory copy expires with the colo copy
const EXPIRES_AT_HEADER = "X-Arul-Jwks-Expires-At";
const FETCHED_AT_HEADER = "X-Arul-Jwks-Fetched-At";
// The Cache API is per colo -> a colo that never fetched has nothing, and its Google fetch can be the one that fails
const KV_KEYS_KEY = "google:jwks";

interface StoredKeys {
  jwks: JSONWebKeySet;
  expiresAt: number;
  fetchedAt: number;
}

/** Google's keys could not be fetched -> the TOKEN was never judged -> handleLogin answers 503, not 401. */
export class GoogleKeysUnavailableError extends Error {
  override name = "GoogleKeysUnavailableError";
}

interface KeySet {
  getKey: ReturnType<typeof createLocalJWKSet>;
  expiresAt: number;
  fetchedAt: number;
}

// Module-level -> reused by every request in the same isolate; the Cache API shares it across the colo's isolates
let _keys: KeySet | null = null;

export interface GoogleIdTokenClaims {
  sub: string;
  email: string;
  email_verified: boolean;
  name: string | undefined;
  /** Absent on tokens minted without a nonce -> older installs still sign in -> handleLogin must tolerate undefined. */
  nonce: string | undefined;
}

/**
 * Every failure THROWS -> GoogleKeysUnavailableError when the keys could not be had, anything else = bad token.
 * `kv` holds the last good key set for every colo; without it only this colo's caches are tried.
 */
export async function verifyGoogleIdToken(
  idToken: string,
  googleWebClientId: string,
  kv?: KVNamespace,
): Promise<GoogleIdTokenClaims> {
  let keys = await loadKeys(kv);

  let payload;
  try {
    ({ payload } = await jwtVerify(idToken, keys.getKey, {
      audience: googleWebClientId,
      issuer: VALID_ISSUERS,
    }));
  } catch (err) {
    // An unknown kid on a set older than the cooldown = Google rotated -> refetch ONCE, verify ONCE more
    if (!(err instanceof errors.JWKSNoMatchingKey) || Date.now() - keys.fetchedAt < KID_MISS_COOLDOWN_MS) {
      throw err;
    }
    keys = await fetchAndStoreKeys(kv);
    ({ payload } = await jwtVerify(idToken, keys.getKey, {
      audience: googleWebClientId,
      issuer: VALID_ISSUERS,
    }));
  }

  // jose already enforces exp -> the missing expiry check is not an oversight -> email_verified is the one left
  if (payload["email_verified"] !== true) {
    throw new Error("Google account email is not verified");
  }

  if (typeof payload.sub !== "string" || !payload.sub) {
    throw new Error("Google idToken missing sub claim");
  }
  if (typeof payload["email"] !== "string") {
    throw new Error("Google idToken missing email claim");
  }

  return {
    sub: payload.sub,
    email: payload["email"] as string,
    email_verified: true,
    name: payload["name"] as string | undefined,
    nonce: typeof payload["nonce"] === "string" ? payload["nonce"] : undefined,
  };
}

async function loadKeys(kv: KVNamespace | undefined): Promise<KeySet> {
  if (_keys && Date.now() < _keys.expiresAt) return _keys;
  const cached = await readCachedKeys();
  if (cached) {
    _keys = cached;
    return cached;
  }
  const shared = await readSharedKeys(kv);
  if (shared && Date.now() < shared.expiresAt) {
    _keys = shared;
    return shared;
  }
  const stale = _keys;
  try {
    return await fetchAndStoreKeys(kv);
  } catch (err) {
    if (!(err instanceof GoogleKeysUnavailableError)) throw err;
    // Google keeps a retired key published for days -> a recently expired copy still verifies during an outage
    const fallback = [stale, shared]
      .filter((k): k is KeySet => k !== null && Date.now() - k.fetchedAt < STALE_KEYS_MAX_MS)
      .sort((a, b) => b.fetchedAt - a.fetchedAt)[0];
    if (fallback) {
      console.warn("[google] JWKS fetch failed, verifying with an expired copy:", err);
      return fallback;
    }
    throw err;
  }
}

// Like the Cache API, KV is an optimisation -> a failed read is a miss, never a failed login
async function readSharedKeys(kv: KVNamespace | undefined): Promise<KeySet | null> {
  if (!kv) return null;
  try {
    const stored = await kv.get<StoredKeys>(KV_KEYS_KEY, "json");
    if (!stored || !Number.isFinite(stored.expiresAt) || !Number.isFinite(stored.fetchedAt)) return null;
    return {
      getKey: createLocalJWKSet(stored.jwks),
      expiresAt: stored.expiresAt,
      fetchedAt: stored.fetchedAt,
    };
  } catch (err) {
    console.warn("[google] JWKS KV read failed:", err);
    return null;
  }
}

// The Cache API is an optimisation only -> every failure here reads as a miss, never as a failed login
// It is a no-op outside a custom domain (workers.dev, previews) and absent in Node tests
function defaultCache(): Cache | null {
  try {
    return typeof caches !== "undefined" && caches.default ? caches.default : null;
  } catch {
    return null;
  }
}

async function readCachedKeys(): Promise<KeySet | null> {
  const cache = defaultCache();
  if (!cache) return null;
  try {
    const res = await cache.match(GOOGLE_JWKS_URL);
    if (!res) return null;
    const expiresAt = Number(res.headers.get(EXPIRES_AT_HEADER));
    const fetchedAt = Number(res.headers.get(FETCHED_AT_HEADER));
    if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) return null;
    const jwks = (await res.json()) as JSONWebKeySet;
    return {
      getKey: createLocalJWKSet(jwks),
      expiresAt,
      fetchedAt: Number.isFinite(fetchedAt) ? fetchedAt : 0,
    };
  } catch (err) {
    console.warn("[google] JWKS cache read failed, fetching from Google:", err);
    return null;
  }
}

async function fetchAndStoreKeys(kv: KVNamespace | undefined): Promise<KeySet> {
  const { jwks, ttlS } = await fetchGoogleJwks();
  let getKey: KeySet["getKey"];
  try {
    getKey = createLocalJWKSet(jwks);
  } catch (err) {
    throw new GoogleKeysUnavailableError("Google JWKS response is malformed", { cause: err });
  }
  const fetchedAt = Date.now();
  const expiresAt = fetchedAt + ttlS * 1000;
  _keys = { getKey, expiresAt, fetchedAt };

  const cache = defaultCache();
  if (cache) {
    try {
      await cache.put(
        GOOGLE_JWKS_URL,
        new Response(JSON.stringify(jwks), {
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": `max-age=${ttlS}`,
            [EXPIRES_AT_HEADER]: String(expiresAt),
            [FETCHED_AT_HEADER]: String(fetchedAt),
          },
        }),
      );
    } catch (err) {
      console.warn("[google] JWKS cache write failed (non-fatal):", err);
    }
  }
  if (kv) {
    // Expires with the outage fallback's limit -> a copy older than that is never used anyway
    try {
      const stored: StoredKeys = { jwks, expiresAt, fetchedAt };
      await kv.put(KV_KEYS_KEY, JSON.stringify(stored), { expirationTtl: STALE_KEYS_MAX_MS / 1000 });
    } catch (err) {
      console.warn("[google] JWKS KV write failed (non-fatal):", err);
    }
  }
  return _keys;
}

async function fetchGoogleJwks(): Promise<{ jwks: JSONWebKeySet; ttlS: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), JWKS_FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(GOOGLE_JWKS_URL, { signal: controller.signal });
    if (res.status !== 200) {
      throw new GoogleKeysUnavailableError(`Google JWKS answered HTTP ${res.status}`);
    }
    const jwks = (await res.json()) as JSONWebKeySet;
    return { jwks, ttlS: ttlFromCacheControl(res.headers.get("Cache-Control")) };
  } catch (err) {
    if (err instanceof GoogleKeysUnavailableError) throw err;
    const reason = controller.signal.aborted ? "timed out" : "failed";
    throw new GoogleKeysUnavailableError(`Google JWKS fetch ${reason}`, { cause: err });
  } finally {
    clearTimeout(timer);
  }
}

function ttlFromCacheControl(header: string | null): number {
  const match = header ? /(?:^|,)\s*max-age=(\d+)/i.exec(header) : null;
  const maxAge = match ? Number(match[1]) : JWKS_DEFAULT_TTL_S;
  return Math.min(JWKS_MAX_TTL_S, Math.max(JWKS_MIN_TTL_S, maxAge));
}
