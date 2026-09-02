/**
 * Auth routes — /auth/login exchanges a Google idToken for our pair; /auth/refresh rotates; /auth/logout revokes.
 *
 * The `sub` in every issued JWT is OUR users.id, NEVER Google's -> google_sub is only an identity lookup key
 * Every Neon query here is parameterized -> no string interpolation reaches SQL on the unauthenticated path
 * referral_code is unique-constrained -> a collision is expected, not exceptional -> retry once with a fresh code
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyGoogleIdToken } from "../lib/google.js";
import {
  signAccessToken,
  signRefreshToken,
  verifyRefreshToken,
  denylistJti,
  claimRefreshJti,
  storeRotationReplay,
  readRotationReplay,
  verifyAccessToken,
} from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { generateReferralCode, captureReferral } from "../lib/referral.js";
import { hashGoogleSub } from "../lib/tombstone.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";

// ── POST /auth/login ─────────────────────────────────────────────────────────

export async function handleLogin(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  let body: {
    idToken?: string;
    referralCode?: string;
    nonce?: string;
  };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { idToken } = body;
  if (!idToken || typeof idToken !== "string") {
    return errorResponse(400, "missing_field", "idToken is required");
  }
  // The referral code the friend arrived with (Play Install Referrer) -> honoured ONLY on first login, below
  const incomingReferralCode =
    typeof body.referralCode === "string" && body.referralCode.trim()
      ? body.referralCode
      : null;
  // 1. Verify Google idToken
  let googleClaims;
  try {
    googleClaims = await verifyGoogleIdToken(idToken, env.GOOGLE_WEB_CLIENT_ID);
  } catch (err) {
    console.error("[auth/login] Google idToken verification failed:", err);
    return errorResponse(401, "invalid_token", "Google idToken is invalid or expired");
  }

  // The app generates one nonce per PROCESS and hands it to GoogleSignIn.initialize()
  // So every ID token that process obtains carries it as a claim, and the exchange sends the same value
  // Equal or both absent -> that is what binds a token to the app process that requested it
  // Both absent is ACCEPTED on purpose -> older installs send no nonce -> requiring one signs them all out
  // Checking the PAIR, not just "the body has one", is what closes the downgrade path
  // Otherwise a nonce-bearing token could be replayed through an old-shaped request
  const requestNonce =
    typeof body.nonce === "string" && body.nonce ? body.nonce : null;
  const tokenNonce = googleClaims.nonce ?? null;
  if ((requestNonce || tokenNonce) && requestNonce !== tokenNonce) {
    const missing = !requestNonce ? "request" : !tokenNonce ? "token" : "neither";
    console.warn(
      `[auth/login] nonce mismatch for google_sub ${googleClaims.sub} (missing: ${missing})`,
    );
    return errorResponse(401, "nonce_mismatch", "Sign-in nonce did not match");
  }

  // Rate limit AFTER verification, keyed by the GOOGLE ACCOUNT -> never by IP
  // India is heavily carrier-grade NAT'd -> thousands of subscribers share one egress IP
  // An IP key would bucket a whole carrier together and 429 real sign-ins as the app grew
  // One Google account signing in 20x a minute is not a person -> the account is the right unit of abuse
  // Placing it after verifyGoogleIdToken means garbage tokens 401 before they ever reach the limiter
  // And the thing actually worth protecting — the Neon read/write below — still sits behind it
  if (!(await allowRequest(env.RL_AUTH, `login:${googleClaims.sub}`))) {
    console.warn(`[auth/login] rate limited google_sub ${googleClaims.sub}`);
    return tooManyRequests("Too many sign-in attempts — please wait a minute");
  }

  const sql = getDb(env);

  try {
    // 2. Upsert the user row, keyed on google_sub
    let userId: string;
    let displayName: string | null;
    let referralCode: string;

    // The returning user is the common case -> ONE statement, never SELECT-then-UPDATE
    // This round trip sits between the account picker and the feed -> every sequential query is visible latency
    // email always syncs from Google; display_name only syncs until the user edits it in-app
    // After that display_name_custom = true and their name wins permanently
    // A Google token with no `name` claim keeps the stored value -> it must never blank the row
    const updated = await sql`
      UPDATE users
      SET display_name = CASE WHEN display_name_custom
                              THEN display_name
                              ELSE COALESCE(${googleClaims.name ?? null}::text, display_name) END,
          email        = ${googleClaims.email}
      WHERE google_sub = ${googleClaims.sub}
      RETURNING id, display_name, referral_code
    `;

    if (updated.length > 0) {
      const row = updated[0];
      userId = row.id as string;
      displayName = row.display_name as string | null;
      referralCode = row.referral_code as string;
    } else {
      // New user -> generate a referral code and insert -> a unique-violation retries once with a fresh code
      const insertUser = async (): Promise<
        Array<Record<string, unknown>>
      > => {
        referralCode = generateReferralCode();
        try {
          return await sql`
            INSERT INTO users (google_sub, email, display_name, referral_code)
            VALUES (
              ${googleClaims.sub},
              ${googleClaims.email},
              ${googleClaims.name ?? null},
              ${referralCode}
            )
            RETURNING id, display_name, referral_code
          `;
        } catch (insertErr: unknown) {
          if (!isUniqueViolation(insertErr)) throw insertErr;
          referralCode = generateReferralCode();
          return await sql`
            INSERT INTO users (google_sub, email, display_name, referral_code)
            VALUES (
              ${googleClaims.sub},
              ${googleClaims.email},
              ${googleClaims.name ?? null},
              ${referralCode}
            )
            RETURNING id, display_name, referral_code
          `;
        }
      };

      // The one-trial guard across deletions -> DELETE /me left a tombstone keyed by HMAC(google_sub)
      // A hit pre-seeds a consumed-trial row -> /payments/initiate routes them to the paid ₹199 setup
      // Deliberately NOT best-effort -> a failure here must FAIL the login, or the guard can be raced
      // The lookup keys on google_sub alone -> it runs CONCURRENTLY with the insert, not after it
      // This is every new user's FIRST login, the most latency-sensitive request in the funnel
      // Promise.all keeps the fail-closed property -> either query failing still fails the login
      const lookupTombstone = async (): Promise<
        Array<Record<string, unknown>>
      > => {
        const tombHash = await hashGoogleSub(
          googleClaims.sub,
          env.TRIAL_TOMBSTONE_SECRET,
        );
        return await sql`
          SELECT trial_end FROM trial_tombstones
          WHERE google_sub_hash = ${tombHash}
          LIMIT 1
        `;
      };

      const [inserted, tomb] = await Promise.all([
        insertUser(),
        lookupTombstone(),
      ]);

      const row = inserted[0];
      userId = row.id as string;
      displayName = row.display_name as string | null;
      referralCode = row.referral_code as string;
      if (tomb.length > 0) {
        await sql`
          INSERT INTO subscriptions (user_id, status, trial_end)
          VALUES (${userId}, 'expired', ${tomb[0].trial_end as Date})
          ON CONFLICT (user_id) DO NOTHING
        `;
      }

      // New user only -> attribute the install to a referrer -> best-effort, a bad code must never break sign-in
      if (incomingReferralCode) {
        try {
          await captureReferral(sql, userId, incomingReferralCode);
        } catch (refErr) {
          console.error("[auth/login] referral capture failed (non-fatal):", refErr);
        }
      }
    }

    // 3. Issue tokens
    const accessToken = await signAccessToken(userId, env.JWT_SECRET);
    const { token: refreshToken } = await signRefreshToken(userId, env.JWT_SECRET);

    return c.json({
      accessToken,
      refreshToken,
      user: {
        id: userId,
        displayName,
        email: googleClaims.email ?? null,
        referralCode,
      },
    });
  } catch (err) {
    console.error("[auth/login] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /auth/refresh ───────────────────────────────────────────────────────

export async function handleRefresh(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  let body: { refreshToken?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { refreshToken } = body;
  if (!refreshToken || typeof refreshToken !== "string") {
    return errorResponse(400, "missing_field", "refreshToken is required");
  }

  // 1. Verify the refresh JWT
  let claims;
  try {
    claims = await verifyRefreshToken(refreshToken, env.JWT_SECRET);
  } catch {
    return errorResponse(401, "invalid_refresh", "Refresh token is invalid or expired");
  }

  // Rate limit AFTER verification, keyed by the USER -> never by IP -> see the carrier-NAT note in handleLogin
  // A 60-minute access token means a normal user refreshes about once an hour -> 20/min is pure abuse headroom
  if (!(await allowRequest(env.RL_AUTH, `refresh:${claims.sub}`))) {
    console.warn(`[auth/refresh] rate limited user ${claims.sub}`);
    return tooManyRequests();
  }

  // Claim the token for rotation -> check-then-act let two concurrent refreshes both see "not denylisted"
  // Both then minted a pair -> one session forked into two -> only the caller that WINS the claim may issue tokens
  const expEpoch = claims.exp ?? Math.floor(Date.now() / 1000);
  const won = await claimRefreshJti(env.KV, claims.jti, expEpoch);
  if (!won) {
    // We lost the rotation -> treating that as a revoked token signs the user OUT -> check for a retry first
    // A client timeout, a dropped connection or a badly timed background all retry a refresh that already succeeded
    // Replaying the same pair inside the window makes a flaky network a no-op instead of a forced re-sign-in
    // This covers the SEQUENTIAL retry, the dominant real case -> two truly simultaneous refreshes can still 401
    // The loser can arrive before the winner has written the replay -> the client's own single-flight prevents that
    const replay = await readRotationReplay(env.KV, claims.jti);
    if (replay) {
      console.log(`[auth/refresh] replaying rotated pair for jti ${claims.jti}`);
      return c.json(replay);
    }
    return errorResponse(401, "invalid_refresh", "Refresh token has been revoked");
  }

  // 4. Issue new pair
  const newAccessToken = await signAccessToken(claims.sub, env.JWT_SECRET);
  const { token: newRefreshToken } = await signRefreshToken(claims.sub, env.JWT_SECRET);

  // Record it BEFORE responding -> a retry that races the response must still find the replay
  await storeRotationReplay(env.KV, claims.jti, {
    accessToken: newAccessToken,
    refreshToken: newRefreshToken,
  });

  return c.json({ accessToken: newAccessToken, refreshToken: newRefreshToken });
}

// ── POST /auth/logout ────────────────────────────────────────────────────────

export async function handleLogout(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  // Require valid access token
  const authHeader = c.req.header("Authorization") ?? "";
  const accessToken = authHeader.replace(/^Bearer\s+/i, "");
  if (!accessToken) {
    return errorResponse(401, "unauthorized", "Authorization header required");
  }
  try {
    await verifyAccessToken(accessToken, env.JWT_SECRET);
  } catch {
    return errorResponse(401, "unauthorized", "Invalid access token");
  }

  let body: { refreshToken?: string };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const { refreshToken } = body;
  if (!refreshToken || typeof refreshToken !== "string") {
    return errorResponse(400, "missing_field", "refreshToken is required");
  }

  // Verify and denylist the refresh token
  let claims;
  try {
    claims = await verifyRefreshToken(refreshToken, env.JWT_SECRET);
  } catch {
    // Already invalid -> logout is idempotent -> still answer ok, never 401 someone out of signing out
    return c.json({ ok: true });
  }

  const expEpoch = claims.exp ?? Math.floor(Date.now() / 1000);
  await denylistJti(env.KV, claims.jti, expEpoch);

  return c.json({ ok: true });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function errorResponse(
  status: number,
  code: string,
  message: string,
): Response {
  return Response.json({ error: { code, message } }, { status });
}

function isUniqueViolation(err: unknown): boolean {
  // postgres.js wraps Postgres errors -> a unique violation is code 23505 on the wrapper, not on the message
  return (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    (err as { code: string }).code === "23505"
  );
}
