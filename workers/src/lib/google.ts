/**
 * Google idToken verification via JWKS.
 *
 * Spec: https://developers.google.com/identity/sign-in/web/backend-auth
 * JWKS: https://www.googleapis.com/oauth2/v3/certs
 *
 * Required checks (per Google docs):
 *   1. Signature valid against Google public JWKS
 *   2. aud == GOOGLE_WEB_CLIENT_ID
 *   3. iss == "accounts.google.com" or "https://accounts.google.com"
 *   4. exp > now  (jose handles this automatically)
 *   5. email_verified == true
 *
 * jose's createRemoteJWKSet caches the keyset and respects Cache-Control
 * from Google's response, which typically has a multi-hour TTL.
 */

import { jwtVerify, createRemoteJWKSet } from "jose";

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const VALID_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];

// Module-level JWKS function — reused across requests in the same Worker isolate.
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
}

/**
 * Verify a Google idToken and return its claims.
 * @throws Error with a descriptive message if verification fails.
 */
export async function verifyGoogleIdToken(
  idToken: string,
  googleWebClientId: string,
): Promise<GoogleIdTokenClaims> {
  const jwks = getGoogleJWKS();

  const { payload } = await jwtVerify(idToken, jwks, {
    audience: googleWebClientId,
    issuer: VALID_ISSUERS,
  });

  // jose validates exp automatically. Check email_verified explicitly.
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
  };
}
