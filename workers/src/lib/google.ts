/**
 * Google idToken verification via JWKS.
 * Spec: https://developers.google.com/identity/sign-in/web/backend-auth · JWKS: /oauth2/v3/certs
 *
 * `aud` is the WEB client id, never the Android one -> an Android-audience token is a different app's token
 * Google issues both bare and https `accounts.google.com` -> accept both issuers or half the tokens fail
 * The `nonce` claim is RETURNED, not checked -> only the caller knows what it asked for -> handleLogin compares
 * createRemoteJWKSet caches the keyset and honours Google's Cache-Control -> keep it module-level, never per-call
 */

import { jwtVerify, createRemoteJWKSet } from "jose";

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const VALID_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];

// Module-level -> reused across every request in the same isolate -> one JWKS fetch, not one per login
let _jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function getGoogleJWKS(): ReturnType<typeof createRemoteJWKSet> {
  if (!_jwks) {
    _jwks = createRemoteJWKSet(new URL(GOOGLE_JWKS_URL));
  }
  return _jwks;
}

export interface GoogleIdTokenClaims {
  sub: string; // stable Google user ID
  email: string;
  email_verified: boolean;
  name: string | undefined;
  /** Absent on tokens minted without a nonce -> older installs still sign in -> handleLogin must tolerate undefined. */
  nonce: string | undefined;
}

/** Every failure THROWS with a descriptive message -> there is no falsy "invalid" return -> callers must catch. */
export async function verifyGoogleIdToken(
  idToken: string,
  googleWebClientId: string,
): Promise<GoogleIdTokenClaims> {
  const jwks = getGoogleJWKS();

  const { payload } = await jwtVerify(idToken, jwks, {
    audience: googleWebClientId,
    issuer: VALID_ISSUERS,
  });

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
