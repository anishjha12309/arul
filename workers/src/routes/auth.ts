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
  isJtiDenylisted,
  verifyAccessToken,
} from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { generateReferralCode, captureReferral } from "../lib/referral.js";
import { hashGoogleSub } from "../lib/tombstone.js";

// ── POST /auth/login ─────────────────────────────────────────────────────────

export async function handleLogin(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  let body: { idToken?: string; referralCode?: string };
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

  // 1. Verify Google idToken
  let googleClaims;
  try {
    googleClaims = await verifyGoogleIdToken(idToken, env.GOOGLE_WEB_CLIENT_ID);
  } catch (err) {
    console.error("[auth/login] Google idToken verification failed:", err);
    return errorResponse(401, "invalid_token", "Google idToken is invalid or expired");
  }

  const sql = getDb(env);

  try {
    // 2. Upsert user row keyed on google_sub
    //    On first login: generate referral code + insert.
    //    On subsequent logins: update display_name.
    //    Uses a CTE to handle the "generate referral code" logic cleanly.
    let userId: string;
    let displayName: string | null;
    let referralCode: string;

    const existing = await sql`
      SELECT id, display_name, display_name_custom, referral_code
      FROM users
      WHERE google_sub = ${googleClaims.sub}
      LIMIT 1
    `;

    if (existing.length > 0) {
      const row = existing[0];
      const isCustom = row.display_name_custom === true;
      // email always syncs from Google. display_name only syncs while the user
      // hasn't customised it in-app — once they edit, their name wins
      // permanently (display_name_custom = true).
      await sql`
        UPDATE users
        SET display_name = CASE WHEN ${isCustom}
                                THEN display_name
                                ELSE ${googleClaims.name ?? null} END,
            email        = ${googleClaims.email}
        WHERE id = ${row.id as string}
      `;
      userId = row.id as string;
      displayName = isCustom
        ? (row.display_name as string | null)
        : (googleClaims.name ?? (row.display_name as string | null));
      referralCode = row.referral_code as string;
    } else {
      // New user — generate a unique referral code
      referralCode = generateReferralCode();

      // Attempt insert; on referral_code collision retry once with a new code
      let inserted;
      try {
        inserted = await sql`
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
        // unique_violation on referral_code — retry with a fresh code
        if (isUniqueViolation(insertErr)) {
          referralCode = generateReferralCode();
          inserted = await sql`
            INSERT INTO users (google_sub, email, display_name, referral_code)
            VALUES (
              ${googleClaims.sub},
              ${googleClaims.email},
              ${googleClaims.name ?? null},
              ${referralCode}
            )
            RETURNING id, display_name, referral_code
          `;
        } else {
          throw insertErr;
        }
      }

      const row = inserted[0];
      userId = row.id as string;
      displayName = row.display_name as string | null;
      referralCode = row.referral_code as string;

      // One-trial guard across deletions: if this Google account previously
      // deleted an Arul account AFTER consuming its free trial, DELETE /me
      // left a tombstone keyed by HMAC(google_sub). Pre-seed a consumed-trial
      // subscriptions row so /payments/initiate routes them to the paid ₹199
      // setup instead of a fresh trial. Deliberately NOT best-effort — a
      // failure here must fail the login, or the guard could be raced.
      const tombHash = await hashGoogleSub(
        googleClaims.sub,
        env.TRIAL_TOMBSTONE_SECRET,
      );
      const tomb = await sql`
        SELECT trial_end FROM trial_tombstones
        WHERE google_sub_hash = ${tombHash}
        LIMIT 1
      `;
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

  // 2. Check KV denylist
  if (await isJtiDenylisted(env.KV, claims.jti)) {
    return errorResponse(401, "invalid_refresh", "Refresh token has been revoked");
  }

  // 3. Denylist the old refresh token
  const expEpoch = claims.exp ?? Math.floor(Date.now() / 1000);
  await denylistJti(env.KV, claims.jti, expEpoch);

  // 4. Issue new pair
  const newAccessToken = await signAccessToken(claims.sub, env.JWT_SECRET);
  const { token: newRefreshToken } = await signRefreshToken(claims.sub, env.JWT_SECRET);

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
