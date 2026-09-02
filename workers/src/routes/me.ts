/**
 * "Me" routes — all JWT-gated, every query scoped to the VERIFIED `sub`, which is users.id.
 *
 * The user id is NEVER read from a request body -> only the verified subject scopes a query here
 * Every response shape matches the Flutter models exactly -> they rename fields to snake_case -> so must every key
 * GET /me re-reads the row rather than trusting the token -> it confirms the row still exists and returns live fields
 * GET /me/subscription is kept only for old clients -> GET /me already carries the same subscription object
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import {
  verifyAccessToken,
  verifyRefreshToken,
  denylistJti,
} from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { premiumPredicate } from "../lib/entitlement.js";
import { revokeMandateTolerant } from "../lib/phonepe.js";
import { hashGoogleSub } from "../lib/tombstone.js";
import { reportPostHogSubscriptionCancel } from "../lib/posthog.js";

// ── GET /me ──────────────────────────────────────────────────────────────────

/**
 * GET /me carries the caller's subscription row in the SAME query — a cold-start merge.
 *
 * The app reads profile and entitlement in one launch request instead of two -> half the startup Neon round trips
 * subscriptions is 1:0..1 to users -> a LEFT JOIN stays a single-row result whether or not they ever subscribed
 * The `user` shape is UNCHANGED -> old builds must keep parsing it -> never rename a key here
 * The `subscription` object matches handleMeSubscription byte for byte -> same keys, same serialization
 */
export async function handleMe(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    // Alias every joined subscriptions column as sub_* -> a shared column name would silently collide with users
    // `premium` is the SERVER-COMPUTED entitlement from premiumPredicate -> the one place the rule lives
    // The app's gate reads THIS flag and never re-derives the rule from the row
    // A client copy of the rule drifted once -> it knew nothing of reward_premium_until
    // That bounced a reward-only referrer to the paywall while /media/signed-url would have signed for them
    // The row still ships alongside -> the premium screen needs status and dates to say anything true
    const rows = await sql`
      SELECT u.id, u.display_name, u.email, u.referral_code,
             s.id AS sub_id, s.user_id AS sub_user_id, s.status AS sub_status,
             s.plan AS sub_plan,
             s.phonepe_subscription_id AS sub_phonepe_subscription_id,
             s.merchant_subscription_id AS sub_merchant_subscription_id,
             s.merchant_order_id AS sub_merchant_order_id,
             s.trial_end AS sub_trial_end,
             s.current_period_end AS sub_current_period_end,
             s.updated_at AS sub_updated_at,
             ${premiumPredicate(sql, sub)} AS premium
      FROM users u
      LEFT JOIN subscriptions s ON s.user_id = u.id
      WHERE u.id = ${sub}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "User not found");
    }
    const row = rows[0];
    // No subscriptions row -> the LEFT JOIN nulls every s.* column -> emit `subscription: null`, not an empty object
    const subscription =
      row.sub_id === null
        ? null
        : {
            id: row.sub_id as string,
            user_id: row.sub_user_id as string,
            status: row.sub_status as string,
            plan: (row.sub_plan as string | null) ?? null,
            phonepe_subscription_id:
              (row.sub_phonepe_subscription_id as string | null) ?? null,
            merchant_subscription_id:
              (row.sub_merchant_subscription_id as string | null) ?? null,
            // The SETUP order id — the same value the app sends as `order_id` -> the trial_started catch-up dedupes on it
            // A trial granted app-closed never fired the event in-session -> a webhook resurrect, or a killed process
            // This is how the next launch knows WHICH trial it still owes -> one event per order, never a repeat
            merchant_order_id: (row.sub_merchant_order_id as string | null) ?? null,
            trial_end: toIso(row.sub_trial_end),
            current_period_end: toIso(row.sub_current_period_end),
            updated_at: toIso(row.sub_updated_at),
          };
    return c.json({
      user: {
        id: row.id as string,
        displayName: row.display_name as string | null,
        email: row.email as string | null,
        referralCode: row.referral_code as string,
      },
      subscription,
      // Additive -> old builds ignore it. Strict === true -> a missing or odd value fails CLOSED, to free
      premium: row.premium === true,
    });
  } catch (err) {
    console.error("[me] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

// ── POST /me/profile ───────────────────────────────────────────────────────────

/** Max display name length -> must match the DB CHECK and the client's counter -> three copies, change all three. */
const MAX_DISPLAY_NAME = 200;

/**
 * POST /me/profile — update the caller's editable profile fields.
 * Setting a name flips display_name_custom = true -> that is what stops login overwriting it from Google
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
 * DELETE /me — permanently delete the caller's account. THE ORDER OF THE THREE STEPS IS LOAD-BEARING.
 *
 * 1. Revoke any live PhonePe mandate FIRST -> deleting the row first keeps debiting a user we no longer know
 *    It aborts with 502 while PhonePe still reports the mandate live -> never delete past that
 * 2. ONE transaction: write the trial tombstone, only when the free trial was consumed, then delete the users row
 *    Everything else cascades -> subscriptions, submissions, referrals; another user's referred_by goes NULL
 * 3. The user's R2 submission objects become orphans -> the sweep cron reclaims them -> no R2 work belongs here
 *    Approved content was COPIED to canonical keys at publish -> it stays in the catalog, anonymous and PII-free
 * The optional { refreshToken } is revoked after deletion -> the access token expires on its own
 * That is safe because every gated action reads live DB state, and the row is gone
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
    // The body is optional -> deletion proceeds with no token to revoke -> never fail a delete over a missing one
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

    // 1. A mandate may be live under any non-terminal status, 'pending' included -> setup can complete after this read
    if (merchantSubId && status !== null && status !== "cancelled" && status !== "expired") {
      const revoked = await revokeMandateTolerant(env, merchantSubId);
      if (!revoked) {
        return errorResponse(
          502,
          "phonepe_error",
          "Could not cancel your subscription with PhonePe. Please try again.",
        );
      }
      // The row is about to cascade-delete with the user -> report the churn NOW, while its prior status is still known
      await reportPostHogSubscriptionCancel(env, {
        userId: sub,
        merchantSubId,
        reason: "account_deleted",
        priorStatus: status,
      });
    }

    // 2. Tombstone (only when the trial was consumed) and the cascade delete, ATOMICALLY -> a split loses the guard
    const trialEnd = row.trial_end as Date | null;
    const subHash =
      trialEnd === null
        ? null
        : await hashGoogleSub(row.google_sub as string, env.TRIAL_TOMBSTONE_SECRET);
    await sql.begin(async (tx) => {
      if (subHash !== null) {
        // ON CONFLICT keeps the EARLIEST tombstone -> it only ever needs to exist, never to be current
        await tx`
          INSERT INTO trial_tombstones (google_sub_hash, trial_end)
          VALUES (${subHash}, ${trialEnd})
          ON CONFLICT (google_sub_hash) DO NOTHING
        `;
      }
      await tx`DELETE FROM users WHERE id = ${sub}`;
    });

    // 3. Revoke the refresh token, best-effort -> the account is gone -> a KV hiccup must not read as a failed delete
    //    The token is useless regardless -> every gated read now 404s, and it expires on its own
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
             phonepe_subscription_id, merchant_subscription_id, merchant_order_id,
             trial_end, current_period_end, updated_at
      FROM subscriptions
      WHERE user_id = ${sub}
      LIMIT 1
    `;
    if (rows.length === 0) {
      return errorResponse(404, "not_found", "No subscription found");
    }

    const row = rows[0];
    // Match SubscriptionModel.fromJson -> dates as ISO-8601 strings for Dart's DateTime.parse, and null stays null
    return c.json({
      id: row.id as string,
      user_id: row.user_id as string,
      status: row.status as string,
      plan: (row.plan as string | null) ?? null,
      phonepe_subscription_id: (row.phonepe_subscription_id as string | null) ?? null,
      merchant_subscription_id: (row.merchant_subscription_id as string | null) ?? null,
      merchant_order_id: (row.merchant_order_id as string | null) ?? null,
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

    // Match ContentSubmissionModel.fromJson, wrapped in { items } -> the app parses no bare array
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
    // The caller's own code, for the share link -> the Refer and Earn screen reads everything from this ONE endpoint
    const me = await sql`SELECT referral_code FROM users WHERE id = ${sub} LIMIT 1`;
    const referralCode = (me[0]?.referral_code as string | undefined) ?? null;

    // Join the referred friend for a display label -> reward_days is only non-zero once 'rewarded' -> SUM gives the total
    const rows = await sql`
      SELECT r.id, r.referrer_id, r.referred_user_id, r.status, r.reward_days,
             r.created_at, u.display_name AS referred_name, u.email AS referred_email
      FROM referrals r
      JOIN users u ON u.id = r.referred_user_id
      WHERE r.referrer_id = ${sub}
      ORDER BY r.created_at DESC
    `;

    // Match ReferralModel.fromJson, wrapped in { items } -> the app parses no bare array
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
        // Prefer the friend's name, then a MASKED email, then null -> the referrer must never see a full address
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

/** Mask an email for the referrer's list -> "amir@gmail.com" becomes "am***@gmail.com" -> never show a full address. */
function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const at = email.indexOf("@");
  if (at <= 0) return null;
  const local = email.slice(0, at);
  const domain = email.slice(at);
  const shown = local.slice(0, Math.min(2, local.length));
  return `${shown}***${domain}`;
}

/** A DB timestamp as ISO-8601, or null -> the Flutter models parse only that shape. */
function toIso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString();
  // postgres.js may return an ISO string already -> pass it through when it parses, never re-wrap blindly
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
