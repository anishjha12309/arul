/**
 * The `sub` in every issued JWT is OUR users.id, NEVER Google's -> google_sub is only an identity lookup key
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyGoogleIdToken, GoogleKeysUnavailableError } from "../lib/google.js";
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
import { generateReferralCode } from "../lib/referral.js";
import { hashGoogleSub } from "../lib/tombstone.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";
import { requestSignal } from "../lib/request-signal.js";

export async function handleLogin(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  let body: {
    idToken?: string;
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
  let googleClaims;
  try {
    googleClaims = await verifyGoogleIdToken(idToken, env.GOOGLE_WEB_CLIENT_ID);
  } catch (err) {
    // Google's keys were unreachable -> the token was never judged -> a 401 would read as a bad account
    if (err instanceof GoogleKeysUnavailableError) {
      console.error("[auth/login] Google signing keys unavailable:", err);
      return errorResponse(503, "google_keys_unavailable", "Google sign-in keys are temporarily unavailable");
    }
    console.error("[auth/login] Google idToken verification failed:", err);
    return errorResponse(401, "invalid_token", "Google idToken is invalid or expired");
  }

  const requestNonce = typeof body.nonce === "string" && body.nonce ? body.nonce : null;
  const tokenNonce = googleClaims.nonce ?? null;
  if ((requestNonce || tokenNonce) && requestNonce !== tokenNonce) {
    const missing = !requestNonce ? "request" : !tokenNonce ? "token" : "neither";
    console.warn(`[auth/login] nonce mismatch for google_sub ${googleClaims.sub} (missing: ${missing})`);
    return errorResponse(401, "nonce_mismatch", "Sign-in nonce did not match");
  }

  // Rate limit AFTER verification, keyed by the GOOGLE ACCOUNT -> never by IP
  // India is heavily carrier-grade NAT'd -> thousands of subscribers share one egress IP
  // An IP key would bucket a whole carrier together and 429 real sign-ins as the app grew
  if (!(await allowRequest(env.RL_AUTH, `login:${googleClaims.sub}`))) {
    console.warn(`[auth/login] rate limited google_sub ${googleClaims.sub}`);
    return tooManyRequests("Too many sign-in attempts — please wait a minute");
  }

  const sql = getDb(env);

  try {
    // ONE statement for every sign-in -> this round trip sits between the account picker and the feed
    // The tombstone lookup and pre-seed ride the SAME statement -> fail-closed, and no new row lands without its seed
    // ON CONFLICT (google_sub) serialises a hedged second POST -> it waits, updates, gets the same id, inserted = false
    const tombHash = await hashGoogleSub(googleClaims.sub, env.TRIAL_TOMBSTONE_SECRET);
    // email always syncs from Google; display_name only syncs until the user edits it in-app
    // After that display_name_custom = true and their name wins permanently
    // A Google token with no `name` claim keeps the stored value -> it must never blank the row
    const upsertUser = (code: string) => sql`
      WITH tomb AS (
        SELECT trial_end FROM trial_tombstones
        WHERE google_sub_hash = ${tombHash}
        LIMIT 1
      ),
      up AS (
        INSERT INTO users (google_sub, email, display_name, referral_code)
        VALUES (${googleClaims.sub}, ${googleClaims.email}, ${googleClaims.name ?? null}, ${code})
        ON CONFLICT (google_sub) DO UPDATE
        SET display_name = CASE WHEN users.display_name_custom
                                THEN users.display_name
                                ELSE COALESCE(EXCLUDED.display_name, users.display_name) END,
            email        = EXCLUDED.email
        RETURNING id, display_name, referral_code, is_internal,
                  floor(extract(epoch FROM now() - created_at) / 86400)::int AS account_age_d,
                  (SELECT s.status FROM subscriptions s WHERE s.user_id = users.id) AS sub_status,
                  (SELECT s.trial_end IS NOT NULL FROM subscriptions s WHERE s.user_id = users.id) AS trial_used,
                  (SELECT s.paid_paise > 0 FROM subscriptions s WHERE s.user_id = users.id) AS paid_before,
                  (xmax = 0) AS inserted
      ),
      seed AS (
        INSERT INTO subscriptions (user_id, status, trial_end)
        SELECT up.id, 'expired', tomb.trial_end FROM up, tomb
        WHERE up.inserted
        ON CONFLICT (user_id) DO NOTHING
      )
      SELECT up.*, (SELECT trial_end FROM tomb) AS tomb_trial_end FROM up
    `;

    let rows;
    try {
      rows = await upsertUser(generateReferralCode());
    } catch (upsertErr: unknown) {
      // A new user's referral code collided -> google_sub never raises here, ON CONFLICT owns it -> retry once
      if (!isUniqueViolation(upsertErr)) throw upsertErr;
      rows = await upsertUser(generateReferralCode());
    }

    const row = rows[0];
    const userId = row.id as string;
    const displayName = row.display_name as string | null;
    const referralCode = row.referral_code as string;
    const isNewUser = row.inserted === true;

    let analytics: LoginAnalytics;
    if (!isNewUser) {
      analytics = {
        new_user: false,
        sub_status: (row.sub_status as string | null) ?? "none",
        trial_used: row.trial_used === true,
        account_age_d: typeof row.account_age_d === "number" ? row.account_age_d : null,
        internal: row.is_internal === true,
        paid_before: row.paid_before === true,
      };
    } else {
      const tombstoned = row.tomb_trial_end != null;
      analytics = {
        new_user: true,
        sub_status: tombstoned ? "expired" : "none",
        trial_used: tombstoned,
        account_age_d: 0,
        internal: false,
        paid_before: false,
      };
    }

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
      // The connection rides AFTER the account facts: build 87 keeps only the first 12 keys it is sent
      analytics: { ...analytics, ...requestSignal(c.req.raw) },
    });
  } catch (err) {
    console.error("[auth/login] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

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

  const newAccessToken = await signAccessToken(claims.sub, env.JWT_SECRET);
  const { token: newRefreshToken } = await signRefreshToken(claims.sub, env.JWT_SECRET);

  // Record it BEFORE responding -> a retry that races the response must still find the replay
  await storeRotationReplay(env.KV, claims.jti, {
    accessToken: newAccessToken,
    refreshToken: newRefreshToken,
  });

  return c.json({ accessToken: newAccessToken, refreshToken: newRefreshToken });
}

export async function handleLogout(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

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

/**
 * Spread verbatim onto the app's `login_success` -> the keys ARE PostHog property names.
 * Analytics only: the premium gate stays `premiumPredicate`, never `sub_status`
 * `trial_used` = this account can no longer start a trial -> the login→trial denominator excludes it
 * `sub_status` is the row's status at sign-in, `none` = never reached checkout
 */
interface LoginAnalytics {
  new_user: boolean;
  sub_status: string;
  trial_used: boolean;
  account_age_d: number | null;
  internal: boolean;
  /** A debit has ever landed on this account -> a returning payer, not a prospect. */
  paid_before: boolean;
}

function errorResponse(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

function isUniqueViolation(err: unknown): boolean {
  // postgres.js wraps Postgres errors -> a unique violation is code 23505 on the wrapper, not on the message
  return (
    typeof err === "object" && err !== null && "code" in err && (err as { code: string }).code === "23505"
  );
}
