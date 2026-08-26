/**
 * Auth routes:
 *   POST /auth/login   — exchange Google idToken for our JWT pair
 *   POST /auth/refresh — rotate tokens (denylist old refresh jti)
 *   POST /auth/logout  — revoke refresh token (add jti to denylist)
 *
 * Security notes:
 *   - All Neon queries are parameterized (no string interpolation).
 *   - The `sub` in the issued JWT is OUR internal users.id (UUID), not
 *     Google's `sub`. Google's sub is stored as google_sub for identity lookup.
 *   - Referral code is unique-constrained; on collision we retry once.
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
import { normalizeAppInstanceId } from "../lib/ga4.js";
import { normalizeMetaAnonId } from "../lib/meta.js";
import { generateReferralCode, captureReferral } from "../lib/referral.js";
import { hashGoogleSub } from "../lib/tombstone.js";
import { allowRequest, tooManyRequests } from "../lib/ratelimit.js";

// ── POST /auth/login ─────────────────────────────────────────────────────────

export async function handleLogin(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  let body: {
    idToken?: string;
    referralCode?: string;
    appInstanceId?: string;
    metaAnonId?: string;
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
  // Optional: referral code the friend arrived with (Play Install Referrer).
  // Only honored on FIRST login (new-user creation) below.
  const incomingReferralCode =
    typeof body.referralCode === "string" && body.referralCode.trim()
      ? body.referralCode
      : null;
  // Optional: Firebase app_instance_id, stored so lib/ga4.ts can attribute
  // app-closed debit settles (trial→paid, renewals) to this user's GA4 stream.
  // Re-sent every login on purpose — the id changes on reinstall/clear-data,
  // and login is the one call such a device is guaranteed to make.
  const appInstanceId = normalizeAppInstanceId(body.appInstanceId);
  // Optional: the Meta SDK's anonymous app device GUID, stored so lib/meta.ts
  // can device-match the app-closed FIRST trial→paid conversion. Same lifecycle
  // as appInstanceId: re-sent every login, changes on reinstall/clear-data.
  const metaAnonId = normalizeMetaAnonId(body.metaAnonId);

  // 1. Verify Google idToken
  let googleClaims;
  try {
    googleClaims = await verifyGoogleIdToken(idToken, env.GOOGLE_WEB_CLIENT_ID);
  } catch (err) {
    console.error("[auth/login] Google idToken verification failed:", err);
    return errorResponse(401, "invalid_token", "Google idToken is invalid or expired");
  }

  // Rate limit AFTER verification, keyed by the GOOGLE ACCOUNT — never by IP.
  //
  // India is heavily carrier-grade NAT'd: thousands of Jio/Airtel subscribers
  // share one egress IP, so an IP key would put every user on that carrier into
  // a single bucket and start 429ing real sign-ins as soon as the app got
  // popular. The account is the correct unit of abuse here — one Google account
  // signing in 20× a minute is not a person.
  //
  // Placing it after verifyGoogleIdToken also means a flood of garbage tokens
  // never reaches the limiter at all (it 401s first), while the thing worth
  // protecting — the Neon read/write below — is behind it.
  if (!(await allowRequest(env.RL_AUTH, `login:${googleClaims.sub}`))) {
    console.warn(`[auth/login] rate limited google_sub ${googleClaims.sub}`);
    return tooManyRequests("Too many sign-in attempts — please wait a minute");
  }

  const sql = getDb(env);

  try {
    // 2. Upsert user row keyed on google_sub
    //    On first login: generate referral code + insert.
    //    On subsequent logins: sync email/display_name in place.
    let userId: string;
    let displayName: string | null;
    let referralCode: string;

    // Returning user — the common case — is ONE statement, not SELECT-then-
    // UPDATE: the login round trip sits between the account picker and the
    // feed, so every sequential Neon query here is user-visible latency
    // (774 ms client-observed, device 2026-08-22).
    //
    // email always syncs from Google. display_name only syncs while the user
    // hasn't customised it in-app — once they edit, their name wins
    // permanently (display_name_custom = true); a Google token without a
    // `name` claim keeps the stored one rather than blanking it.
    // COALESCE so a build that doesn't send the id can never blank a stored
    // one. ::text casts — fetch_types:false (Hyperdrive) gives Postgres no
    // context to infer a bare parameter's type inside COALESCE.
    const updated = await sql`
      UPDATE users
      SET display_name = CASE WHEN display_name_custom
                              THEN display_name
                              ELSE COALESCE(${googleClaims.name ?? null}::text, display_name) END,
          email        = ${googleClaims.email},
          app_instance_id = COALESCE(${appInstanceId}::text, app_instance_id),
          meta_anon_id    = COALESCE(${metaAnonId}::text, meta_anon_id)
      WHERE google_sub = ${googleClaims.sub}
      RETURNING id, display_name, referral_code
    `;

    if (updated.length > 0) {
      const row = updated[0];
      userId = row.id as string;
      displayName = row.display_name as string | null;
      referralCode = row.referral_code as string;
    } else {
      // New user — generate a unique referral code, then insert; on a
      // referral_code collision retry once with a fresh code.
      const insertUser = async (): Promise<
        Array<Record<string, unknown>>
      > => {
        referralCode = generateReferralCode();
        try {
          return await sql`
            INSERT INTO users (google_sub, email, display_name, referral_code, app_instance_id, meta_anon_id)
            VALUES (
              ${googleClaims.sub},
              ${googleClaims.email},
              ${googleClaims.name ?? null},
              ${referralCode},
              ${appInstanceId}::text,
              ${metaAnonId}::text
            )
            RETURNING id, display_name, referral_code
          `;
        } catch (insertErr: unknown) {
          if (!isUniqueViolation(insertErr)) throw insertErr;
          referralCode = generateReferralCode();
          return await sql`
            INSERT INTO users (google_sub, email, display_name, referral_code, app_instance_id, meta_anon_id)
            VALUES (
              ${googleClaims.sub},
              ${googleClaims.email},
              ${googleClaims.name ?? null},
              ${referralCode},
              ${appInstanceId}::text,
              ${metaAnonId}::text
            )
            RETURNING id, display_name, referral_code
          `;
        }
      };

      // One-trial guard across deletions: if this Google account previously
      // deleted an Arul account AFTER consuming its free trial, DELETE /me
      // left a tombstone keyed by HMAC(google_sub). Pre-seed a consumed-trial
      // subscriptions row so /payments/initiate routes them to the paid ₹199
      // setup instead of a fresh trial. Deliberately NOT best-effort — a
      // failure here must fail the login, or the guard could be raced.
      //
      // The lookup keys on google_sub alone, so it runs CONCURRENTLY with the
      // insert instead of after it — this is every genuinely-new user's FIRST
      // login, the most latency-sensitive request in the funnel, and the two
      // queries are independent. Promise.all keeps the fail-closed property:
      // either failing still fails the login.
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

      // New user only: attribute the install to a referrer, if one was passed.
      // Best-effort — a bad/unknown code must never break sign-in.
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

  // Rate limit AFTER verification, keyed by the USER — never by IP (see the
  // carrier-NAT note in handleLogin). With a 60-minute access token a normal
  // user refreshes about once an hour; 20/min per user is pure abuse headroom.
  if (!(await allowRequest(env.RL_AUTH, `refresh:${claims.sub}`))) {
    console.warn(`[auth/refresh] rate limited user ${claims.sub}`);
    return tooManyRequests();
  }

  // 2 + 3. Claim the token for rotation. This replaces the old
  // check-then-act (isJtiDenylisted, then denylistJti), under which two
  // concurrent refreshes with the SAME token both saw "not denylisted" and both
  // minted a pair — forking one session into two. Only the caller that wins the
  // claim may issue new tokens; the loser is told to retry.
  const expEpoch = claims.exp ?? Math.floor(Date.now() / 1000);
  const won = await claimRefreshJti(env.KV, claims.jti, expEpoch);
  if (!won) {
    // We did not win the rotation. Before treating this as a revoked token —
    // which signs the user out — check whether it is simply a RETRY of a
    // refresh that already succeeded (client timed out waiting, connection
    // dropped mid-flight, app backgrounded at the wrong moment). In that
    // window, replay the same pair so a flaky network is a no-op instead of a
    // forced re-sign-in.
    //
    // Limitation, stated honestly: this covers the dominant real case (a
    // SEQUENTIAL retry seconds later). Two genuinely simultaneous refreshes can
    // still have the loser arrive before the winner has written the replay, and
    // it will 401 — the client's own single-flight is what prevents that.
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

  // Record it BEFORE responding so a retry that races the response still finds it.
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
    // Already invalid — still return ok (idempotent logout)
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
  // postgres.js wraps Postgres errors; unique violation = code 23505
  return (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    (err as { code: string }).code === "23505"
  );
}
