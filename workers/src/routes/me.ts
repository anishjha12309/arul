/**
 * "Me" routes — all JWT-gated, scoped to the verified `sub`.
 *
 *   GET /me               — current user identity (cold-start recovery)
 *   GET /me/subscription  — current subscription row (404 if none)
 *   GET /me/submissions   — caller's content_submissions { items: [...] }
 *   GET /me/referrals     — caller's referrals as referrer { items: [...] }
 *
 * Response shapes match the Flutter models exactly. Those models use
 * `@JsonSerializable(fieldRename: FieldRename.snake)`, so every JSON key is
 * snake_case (user_id, current_period_end, reward_days, file_key, ...).
 *
 * Security:
 *   - `sub` is the verified JWT subject = users.id (uuid). We NEVER read it
 *     from the request body. Every query is parameterized and scoped to `sub`.
 *   - GET /me returns users.id (uuid) so the app can recover the real user id
 *     on cold start (the JWT sub IS users.id, but we re-read to confirm the row
 *     still exists and to return current profile fields).
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import {
  verifyAccessToken,
  verifyRefreshToken,
  denylistJti,
} from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { revokeMandateTolerant } from "../lib/phonepe.js";
import { hashGoogleSub } from "../lib/tombstone.js";

// ── GET /me ──────────────────────────────────────────────────────────────────

export async function handleMe(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT id, display_name, email, referral_code
      FROM users
      WHERE id = ${sub}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "User not found");
    }
    const row = rows[0];
    return c.json({
      user: {
        id: row.id as string,
        displayName: row.display_name as string | null,
        email: row.email as string | null,
        referralCode: row.referral_code as string,
      },
    });
  } catch (err) {
    console.error("[me] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /me/profile ───────────────────────────────────────────────────────────

/** Max display name length — must match the DB CHECK and the client counter. */
const MAX_DISPLAY_NAME = 200;

/**
 * POST /me/profile — update the caller's editable profile fields.
 *
 * Body: { displayName: string }. The name is trimmed; it must be non-empty and
 * at most MAX_DISPLAY_NAME chars. Setting it flips display_name_custom = true so
 * the login handler stops overwriting it from Google. Scoped to the verified
 * `sub` — the user id is NEVER read from the body.
 */
export async function handleUpdateProfile(
  c: Context<{ Bindings: Env }>,
): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: { displayName?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  if (typeof body.displayName !== "string") {
    return errorResponse(400, "missing_field", "displayName is required");
  }
  const displayName = body.displayName.trim();
  if (displayName.length === 0) {
    return errorResponse(400, "invalid_name", "Name cannot be empty");
  }
  if (displayName.length > MAX_DISPLAY_NAME) {
    return errorResponse(
      400,
      "invalid_name",
      `Name must be at most ${MAX_DISPLAY_NAME} characters`,
    );
  }

  const sql = getDb(env);
  try {
    const rows = await sql`
      UPDATE users
      SET display_name = ${displayName},
          display_name_custom = true
      WHERE id = ${sub}
      RETURNING id, display_name, email, referral_code
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "User not found");
    }
    const row = rows[0];
    return c.json({
      user: {
        id: row.id as string,
        displayName: row.display_name as string | null,
        email: row.email as string | null,
        referralCode: row.referral_code as string,
      },
    });
  } catch (err) {
    console.error("[me/profile] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── DELETE /me ───────────────────────────────────────────────────────────────

/**
 * DELETE /me — permanently delete the caller's account.
 *
 * Body (optional): { refreshToken } — revoked after successful deletion so the
 * old session dies immediately (the ≤15m access token expires on its own; all
 * gated actions read live DB state, which is gone).
 *
 * Order matters:
 *   1. Revoke any live PhonePe mandate FIRST — deleting the row while the
 *      mandate stays live would keep debiting a user we no longer know.
 *      Aborts with 502 if PhonePe still reports the mandate live.
 *   2. One transaction: write the trial tombstone (only when the free trial
 *      was consumed — see lib/tombstone.ts), then delete the users row.
 *      Everything else cascades (subscriptions, content_submissions,
 *      referrals; other users' referred_by goes NULL).
 *   3. The user's R2 submission objects become orphans and are reclaimed by
 *      the hourly sweep-submissions cron — no R2 work here. Approved content
 *      was COPIED to canonical keys at publish time and stays in the catalog
 *      (anonymous app content, no PII).
 */
export async function handleDeleteAccount(
  c: Context<{ Bindings: Env }>,
): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let refreshToken: string | null = null;
  try {
    const body = (await c.req.json()) as { refreshToken?: unknown };
    if (typeof body.refreshToken === "string") refreshToken = body.refreshToken;
  } catch {
    // Body is optional — deletion proceeds without a token to revoke.
  }

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT u.google_sub, s.status, s.merchant_subscription_id, s.trial_end
      FROM users u
      LEFT JOIN subscriptions s ON s.user_id = u.id
      WHERE u.id = ${sub}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "User not found");
    }
    const row = rows[0];
    const status = row.status as string | null;
    const merchantSubId = row.merchant_subscription_id as string | null;

    // 1. A mandate may be live for any non-terminal status ('pending' included
    //    — setup can complete at PhonePe after we read the row).
    if (merchantSubId && status !== null && status !== "cancelled" && status !== "expired") {
      const revoked = await revokeMandateTolerant(env, merchantSubId);
      if (!revoked) {
        return errorResponse(
          502,
          "phonepe_error",
          "Could not cancel your subscription with PhonePe. Please try again.",
        );
      }
    }

    // 2. Tombstone (trial consumed only) + cascade delete, atomically.
    const trialEnd = row.trial_end as Date | null;
    const subHash =
      trialEnd === null
        ? null
        : await hashGoogleSub(row.google_sub as string, env.TRIAL_TOMBSTONE_SECRET);
    await sql.begin(async (tx) => {
      if (subHash !== null) {
        // ON CONFLICT keeps the earliest tombstone — it only needs to exist.
        await tx`
          INSERT INTO trial_tombstones (google_sub_hash, trial_end)
          VALUES (${subHash}, ${trialEnd})
          ON CONFLICT (google_sub_hash) DO NOTHING
        `;
      }
      await tx`DELETE FROM users WHERE id = ${sub}`;
    });

    // 3. Revoke the refresh token. Best-effort: the account is already gone,
    //    so a KV hiccup here must NOT surface as a delete failure — the token
    //    is useless anyway (every gated read now 404s) and expires on its own.
    if (refreshToken) {
      try {
        const claims = await verifyRefreshToken(refreshToken, env.JWT_SECRET);
        const expEpoch = claims.exp ?? Math.floor(Date.now() / 1000);
        await denylistJti(env.KV, claims.jti, expEpoch);
      } catch (revokeErr) {
        console.warn("[me/delete] refresh revoke failed (non-fatal):", revokeErr);
      }
    }

    return c.json({ ok: true });
  } catch (err) {
    console.error("[me/delete] error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── GET /me/subscription ─────────────────────────────────────────────────────

export async function handleMeSubscription(
  c: Context<{ Bindings: Env }>,
): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT id, user_id, status, plan,
             phonepe_subscription_id, merchant_subscription_id,
             trial_end, current_period_end, updated_at
      FROM subscriptions
      WHERE user_id = ${sub}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "No subscription found");
    }

    const row = rows[0];
    // Match SubscriptionModel.fromJson (snake_case). Dates as ISO-8601 strings
    // so Dart's DateTime.parse accepts them; null stays null.
    return c.json({
      id: row.id as string,
      user_id: row.user_id as string,
      status: row.status as string,
      plan: (row.plan as string | null) ?? null,
      phonepe_subscription_id: (row.phonepe_subscription_id as string | null) ?? null,
      merchant_subscription_id: (row.merchant_subscription_id as string | null) ?? null,
      trial_end: toIso(row.trial_end),
      current_period_end: toIso(row.current_period_end),
      updated_at: toIso(row.updated_at),
    });
  } catch (err) {
    console.error("[me/subscription] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── GET /me/submissions ──────────────────────────────────────────────────────

export async function handleMeSubmissions(
  c: Context<{ Bindings: Env }>,
): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT id, user_id, kind, file_key, title, category,
             status, rejection_reason, reviewed_by, created_at
      FROM content_submissions
      WHERE user_id = ${sub}
      ORDER BY created_at DESC
    `;

    // Match ContentSubmissionModel.fromJson (snake_case), wrapped in { items }.
    const items = rows.map((row) => ({
      id: row.id as string,
      user_id: row.user_id as string,
      kind: row.kind as string,
      file_key: row.file_key as string,
      title: (row.title as string | null) ?? null,
      category: (row.category as string | null) ?? null,
      status: row.status as string,
      rejection_reason: (row.rejection_reason as string | null) ?? null,
      reviewed_by: (row.reviewed_by as string | null) ?? null,
      created_at: toIso(row.created_at),
    }));

    return c.json({ items });
  } catch (err) {
    console.error("[me/submissions] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── GET /me/referrals ────────────────────────────────────────────────────────

export async function handleMeReferrals(
  c: Context<{ Bindings: Env }>,
): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    // The caller's own code (for the share link) — the Refer & Earn screen reads
    // everything it needs from this one endpoint.
    const me = await sql`SELECT referral_code FROM users WHERE id = ${sub} LIMIT 1`;
    const referralCode = (me[0]?.referral_code as string | undefined) ?? null;

    // Join the referred friend for a display label. reward_days is 30 once
    // 'rewarded', 0 otherwise, so total_reward_days = SUM(reward_days).
    const rows = await sql`
      SELECT r.id, r.referrer_id, r.referred_user_id, r.status, r.reward_days,
             r.created_at, u.display_name AS referred_name, u.email AS referred_email
      FROM referrals r
      JOIN users u ON u.id = r.referred_user_id
      WHERE r.referrer_id = ${sub}
      ORDER BY r.created_at DESC
    `;

    // Match ReferralModel.fromJson (snake_case), wrapped in { items }.
    let totalRewardDays = 0;
    const items = rows.map((row) => {
      const rewardDays = Number(row.reward_days);
      totalRewardDays += rewardDays;
      return {
        id: row.id as string,
        referrer_id: row.referrer_id as string,
        referred_user_id: row.referred_user_id as string,
        status: row.status as string,
        reward_days: rewardDays,
        created_at: toIso(row.created_at),
        // Prefer the friend's name; fall back to a masked email; else null.
        referred_name:
          (row.referred_name as string | null)?.trim() ||
          maskEmail(row.referred_email as string | null),
      };
    });

    return c.json({
      referral_code: referralCode,
      items,
      total_reward_days: totalRewardDays,
    });
  } catch (err) {
    console.error("[me/referrals] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Mask an email for display in the referrer's list (privacy — the referrer
 * should not see a friend's full address). "amir@gmail.com" → "am***@gmail.com".
 * Returns null for null/blank input.
 */
function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const at = email.indexOf("@");
  if (at <= 0) return null;
  const local = email.slice(0, at);
  const domain = email.slice(at);
  const shown = local.slice(0, Math.min(2, local.length));
  return `${shown}***${domain}`;
}

/** Convert a DB timestamp value to an ISO-8601 string, or null. */
function toIso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString();
  // postgres.js may return ISO strings already; pass through if parseable
  const d = new Date(value as string);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

async function requireAuth(c: Context<{ Bindings: Env }>): Promise<string | null> {
  const authHeader = c.req.header("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  try {
    const claims = await verifyAccessToken(token, c.env.JWT_SECRET);
    return claims.sub;
  } catch {
    return null;
  }
}

function errorResponse(status: number, code: string, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}
