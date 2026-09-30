/**
 * The user id is NEVER read from a request body -> only the verified subject scopes a query here
 * Every response shape matches the Flutter models exactly -> they rename fields to snake_case -> so must every key
 * GET /me re-reads the row rather than trusting the token -> it confirms the row still exists and returns live fields
 */

import type { Context } from "hono";
import type { Env } from "../env.js";
import { verifyAccessToken, verifyRefreshToken, denylistJti } from "../lib/jwt.js";
import { getDb } from "../lib/db.js";
import { premiumPredicate } from "../lib/entitlement.js";
import { STANDARD_PRICE_PAISE } from "../lib/pricing.js";
import { cancelOfferEligible } from "../lib/subscription-state.js";
import { revokeMandateTolerant } from "../lib/phonepe.js";
import { hashGoogleSub } from "../lib/tombstone.js";
import { reportPostHogSubscriptionCancel } from "../lib/posthog.js";
import { type AnalyticsContext, sanitizeAnalyticsContext } from "../lib/analytics-context.js";
import { requestSignal } from "../lib/request-signal.js";

/**
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
             s.price_paise AS sub_price_paise,
             COALESCE(${cancelOfferEligible(sql)}, false) AS sub_cancel_offer_eligible,
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
            phonepe_subscription_id: (row.sub_phonepe_subscription_id as string | null) ?? null,
            merchant_subscription_id: (row.sub_merchant_subscription_id as string | null) ?? null,
            // The SETUP order id — the same value the app sends as `order_id` -> the trial_started catch-up dedupes on it
            // A trial granted app-closed never fired the event in-session -> a webhook resurrect, or a killed process
            // This is how the next launch knows WHICH trial it still owes -> one event per order, never a repeat
            merchant_order_id: (row.sub_merchant_order_id as string | null) ?? null,
            trial_end: toIso(row.sub_trial_end),
            current_period_end: toIso(row.sub_current_period_end),
            updated_at: toIso(row.sub_updated_at),
            price_paise: Number(row.sub_price_paise ?? STANDARD_PRICE_PAISE),
            cancel_offer_eligible: row.sub_cancel_offer_eligible === true,
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

/** Max display name length -> must match the DB CHECK and the client's counter -> three copies, change all three. */
const MAX_DISPLAY_NAME = 200;

/**
 * POST /me/profile — update the caller's editable profile fields.
 * Setting a name flips display_name_custom = true -> that is what stops login overwriting it from Google
 */
export async function handleUpdateProfile(c: Context<{ Bindings: Env }>): Promise<Response> {
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
    return errorResponse(400, "invalid_name", `Name must be at most ${MAX_DISPLAY_NAME} characters`);
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

/**
 * DELETE /me — permanently delete the caller's account. THE ORDER OF THE THREE STEPS IS LOAD-BEARING.
 * 1. Revoke any live PhonePe mandate FIRST -> deleting the row first keeps debiting a user we no longer know
 *    It aborts with 502 while PhonePe still reports the mandate live -> never delete past that
 */
export async function handleDeleteAccount(c: Context<{ Bindings: Env }>): Promise<Response> {
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
      SELECT u.google_sub, u.cancel_offer_at, s.status, s.merchant_subscription_id, s.superseded_mandate_id,
             s.offer_mandate_id, s.revoke_retry_mandate_id, s.offer_switch, s.trial_end, s.price_paise
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
      const parkedMandateId = (row.superseded_mandate_id as string | null | undefined) ?? null;
      // A pending switch's ₹99 was never approved -> an in-progress setup refuses a revoke, so it is best effort,
      // exactly as on cancel; the parked ₹199 is the mandate that bills
      const pendingSwitch = status === "pending" && row.offer_switch === true;
      if (pendingSwitch && !(await revokeMandateTolerant(env, merchantSubId))) {
        console.error(
          `[me/delete] mandate ${merchantSubId} may STILL BE LIVE at PhonePe — manual revoke required`,
        );
      }
      const revoked =
        (pendingSwitch || (await revokeMandateTolerant(env, merchantSubId))) &&
        (parkedMandateId === null ||
          parkedMandateId === merchantSubId ||
          (await revokeMandateTolerant(env, parkedMandateId)));
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
        pricePaise: row.price_paise == null ? null : Number(row.price_paise),
      });
    }

    // A watched ₹99 and a ₹199 the switch could not revoke were never notified, so neither can debit -> best effort,
    // since no row will be left for the hourly sweep to retry
    for (const extra of [row.offer_mandate_id, row.revoke_retry_mandate_id] as (string | null)[]) {
      if (extra && !(await revokeMandateTolerant(env, extra))) {
        console.error(`[me/delete] mandate ${extra} may STILL BE LIVE at PhonePe — manual revoke required`);
      }
    }

    // 2. Tombstone (only when the trial was consumed) and the cascade delete, ATOMICALLY -> a split loses the guard
    // The cancel offer needs a live trialing/active row, so a spent offer always rides a tombstone
    const trialEnd = row.trial_end as Date | null;
    const cancelOfferAt = (row.cancel_offer_at as Date | null | undefined) ?? null;
    const subHash =
      trialEnd === null ? null : await hashGoogleSub(row.google_sub as string, env.TRIAL_TOMBSTONE_SECRET);
    await sql.begin(async (tx) => {
      if (subHash !== null) {
        // The EARLIEST tombstone wins -> it only ever needs to exist; a later deletion only fills a stamp it lacked
        await tx`
          INSERT INTO trial_tombstones (google_sub_hash, trial_end, cancel_offer_at)
          VALUES (${subHash}, ${trialEnd}, ${cancelOfferAt})
          ON CONFLICT (google_sub_hash) DO UPDATE
          SET trial_end       = COALESCE(trial_tombstones.trial_end, EXCLUDED.trial_end),
              cancel_offer_at = COALESCE(trial_tombstones.cancel_offer_at, EXCLUDED.cancel_offer_at)
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

export async function handleMeSubscription(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  const sql = getDb(env);
  try {
    const rows = await sql`
      SELECT s.id, s.user_id, s.status, s.plan,
             s.phonepe_subscription_id, s.merchant_subscription_id, s.merchant_order_id,
             s.trial_end, s.current_period_end, s.updated_at, s.price_paise,
             ${cancelOfferEligible(sql)} AS cancel_offer_eligible
      FROM subscriptions AS s
      JOIN users AS u ON u.id = s.user_id
      WHERE s.user_id = ${sub}
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
      price_paise: Number(row.price_paise ?? STANDARD_PRICE_PAISE),
      cancel_offer_eligible: row.cancel_offer_eligible === true,
    });
  } catch (err) {
    console.error("[me/subscription] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

export async function handleMeSubmissions(c: Context<{ Bindings: Env }>): Promise<Response> {
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

export async function handleMeReferrals(c: Context<{ Bindings: Env }>): Promise<Response> {
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
          (row.referred_name as string | null)?.trim() || maskEmail(row.referred_email as string | null),
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

/**
 * Duplicated by necessity (the Worker has no Dart) -> a seventh language is an edit here, in
 * `routes/deeplink.ts`'s LANG_RE and in `supportedAppLocales`. Anything unrecognised becomes `en`
 * rather than being rejected: a phone whose locale this Worker has never heard of must still register
 * and still receive the English text, not silently drop out of every audience.
 */
const PUSH_LANG_RE = /^(en|ta|te|kn|ml|hi)$/;

function normalizePushLang(raw: unknown): string {
  if (typeof raw !== "string") return "en";
  const bare = raw.trim().toLowerCase().split(/[-_]/)[0] ?? "";
  return PUSH_LANG_RE.test(bare) ? bare : "en";
}

/**
 * ONE PHONE, ONE SIGNED-IN USER. A FID that reappears under a different account is RE-POINTED, never
 * duplicated: the alternative is the previous owner of a shared phone receiving the new owner's
 * segment. Every field but `fid` is optional so a later build can send less without a Worker deploy.
 */
export async function handleRegisterDevice(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let body: Record<string, unknown>;
  try {
    body = (await c.req.json()) as Record<string, unknown>;
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const device = readDeviceBody(body);
  if (!device) return errorResponse(400, "missing_field", "fid is required");
  const { fid, token, lang, appBuild, androidSdk } = device;

  const sql = getDb(env);
  try {
    await sql`
      INSERT INTO push_devices (fid, user_id, token, lang, app_build, android_sdk, last_seen_at)
      VALUES (${fid}, ${sub}, ${token}, ${lang}, ${appBuild}, ${androidSdk}, now())
      ON CONFLICT (fid) DO UPDATE
        SET user_id      = EXCLUDED.user_id,
            -- COALESCE, not EXCLUDED: a build that omits the token must not erase one already stored.
            token        = COALESCE(EXCLUDED.token, push_devices.token),
            lang         = EXCLUDED.lang,
            app_build    = COALESCE(EXCLUDED.app_build, push_devices.app_build),
            android_sdk  = COALESCE(EXCLUDED.android_sdk, push_devices.android_sdk),
            last_seen_at = now()
    `;
    return c.json({ ok: true });
  } catch (err) {
    console.error("[me/device] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

interface DeviceBody {
  fid: string;
  token: string | null;
  lang: string;
  appBuild: number | null;
  androidSdk: number | null;
}

function readDeviceBody(body: Record<string, unknown>): DeviceBody | null {
  const fid = typeof body["fid"] === "string" ? body["fid"].trim() : "";
  if (!fid || fid.length > 256) return null;
  return {
    fid,
    token: typeof body["token"] === "string" && body["token"].length > 0 ? body["token"] : null,
    lang: normalizePushLang(body["lang"]),
    appBuild: Number.isFinite(Number(body["appBuild"])) ? Math.floor(Number(body["appBuild"])) : null,
    androidSdk: Number.isFinite(Number(body["androidSdk"])) ? Math.floor(Number(body["androidSdk"])) : null,
  };
}

/** A registration body is a fid, a token and three scalars — far below this. */
const ANON_DEVICE_BODY_MAX_BYTES = 2048;

/**
 * Unauthenticated writes are safe to accept: a junk fid with an unroutable token comes back
 * UNREGISTERED on its first send and the dispatcher deletes it.
 */
export async function handleRegisterAnonDevice(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;

  const raw = await c.req.text().catch(() => "");
  if (new TextEncoder().encode(raw).length > ANON_DEVICE_BODY_MAX_BYTES) {
    return errorResponse(413, "body_too_large", "Request body is too large");
  }
  let body: Record<string, unknown>;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") throw new Error("not an object");
    body = parsed as Record<string, unknown>;
  } catch {
    return errorResponse(400, "invalid_body", "Request body must be valid JSON");
  }

  const device = readDeviceBody(body);
  if (!device) return errorResponse(400, "missing_field", "fid is required");
  const { fid, token, lang, appBuild, androidSdk } = device;

  const sql = getDb(env);
  try {
    await sql`
      INSERT INTO push_devices (fid, token, lang, app_build, android_sdk, last_seen_at)
      VALUES (${fid}, ${token}, ${lang}, ${appBuild}, ${androidSdk}, now())
      ON CONFLICT (fid) DO UPDATE
        SET token        = COALESCE(EXCLUDED.token, push_devices.token),
            lang         = EXCLUDED.lang,
            app_build    = COALESCE(EXCLUDED.app_build, push_devices.app_build),
            android_sdk  = COALESCE(EXCLUDED.android_sdk, push_devices.android_sdk),
            last_seen_at = now()
    `;
    return c.json({ ok: true });
  } catch (err) {
    console.error("[push/device] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

/**
 * Keyed per USER, not per device: the same person tapping the same campaign on two phones is ONE
 * open, which is what "Opened 14.8%" has to mean on the CMS card. `ON CONFLICT DO NOTHING` is the
 * whole dedup — a tap replayed by `getInitialMessage()` on a relaunch must not inflate the number.
 * A body naming a campaign that does not exist is accepted and ignored, never a 4xx: the app fires
 * this off the tap path and an error there would be noise in Crashlytics, not information.
 */
export async function handlePushOpened(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let campaignId: string | null = null;
  try {
    const body = (await c.req.json()) as { campaign_id?: unknown };
    if (typeof body.campaign_id === "string") campaignId = body.campaign_id.trim();
  } catch {
    // fall through to validation
  }
  if (!campaignId || !UUID_RE.test(campaignId)) {
    return errorResponse(400, "invalid_body", "campaign_id is required");
  }

  const sql = getDb(env);
  try {
    await sql`
      INSERT INTO push_opens (campaign_id, user_id)
      SELECT ${campaignId}, ${sub}
      WHERE EXISTS (SELECT 1 FROM push_campaigns WHERE id = ${campaignId})
      ON CONFLICT DO NOTHING
    `;
    return c.json({ ok: true });
  } catch (err) {
    console.error("[me/push-opened] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

/**
 * One paywall view -> `paywall_views`, per user per gate, which PostHog reads through its warehouse:
 * the people who look and never tap stay visible without a PostHog event.
 * Analytics only -> the app fires it off the paywall's first frame and ignores every answer.
 */
export async function handlePaywallView(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let source: string | null = null;
  let context: AnalyticsContext | null = null;
  let exit: string | null = null;
  let dwellS: number | null = null;
  try {
    const body = (await c.req.json()) as {
      source?: unknown;
      context?: unknown;
      exit?: unknown;
      dwell_s?: unknown;
    };
    if (typeof body.source === "string" && PAYWALL_SOURCE_RE.test(body.source)) source = body.source;
    context = sanitizeAnalyticsContext(body.context);
    if (typeof body.exit === "string" && PAYWALL_SOURCE_RE.test(body.exit)) exit = body.exit;
    if (typeof body.dwell_s === "number" && Number.isFinite(body.dwell_s) && body.dwell_s >= 0) {
      dwellS = Math.min(Math.round(body.dwell_s), 86_400);
    }
  } catch {
    // fall through: no source
  }
  if (!source) return errorResponse(400, "invalid_body", "source is required");

  const sql = getDb(env);
  try {
    if (exit) {
      // How the latest view of this gate ended -> the look-and-leave half the view count cannot show
      await sql`
        UPDATE paywall_views
        SET last_exit = ${exit}, last_dwell_s = ${dwellS}
        WHERE user_id = ${sub} AND source = ${source}
      `;
      return c.json({ ok: true });
    }
    const stored = { ...(context ?? {}), ...requestSignal(c.req.raw) };
    // Bound as TEXT, then cast: postgres.js JSON-encodes a parameter it sees typed jsonb, so a
    // pre-stringified value would land as a jsonb STRING (PGlite does not reproduce this)
    await sql`
      INSERT INTO paywall_views (user_id, source, context)
      VALUES (${sub}, ${source}, ${Object.keys(stored).length ? JSON.stringify(stored) : null}::text::jsonb)
      ON CONFLICT (user_id, source)
      DO UPDATE SET views        = paywall_views.views + 1,
                    last_at      = now(),
                    context      = EXCLUDED.context,
                    last_exit    = NULL,
                    last_dwell_s = NULL
    `;
    return c.json({ ok: true });
  } catch (err) {
    console.error("[me/paywall-view] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

/**
 * One checkout outcome the app saw (a failure with its reason, time in the UPI app, the link) ->
 * `checkout_events`, append-only, read by PostHog's warehouse. Never the subscriptions row: its
 * trigger bumps `updated_at`, which also bounds the in-flight checkout window.
 */
export async function handleCheckoutEvent(c: Context<{ Bindings: Env }>): Promise<Response> {
  const env = c.env;
  const sub = await requireAuth(c);
  if (!sub) return errorResponse(401, "unauthorized", "Authorization required");

  let kind: string | null = null;
  let orderId: string | null = null;
  let context: AnalyticsContext | null = null;
  try {
    const body = (await c.req.json()) as { kind?: unknown; merchant_order_id?: unknown; context?: unknown };
    if (typeof body.kind === "string" && CHECKOUT_KIND_RE.test(body.kind)) kind = body.kind;
    if (typeof body.merchant_order_id === "string" && ORDER_ID_RE.test(body.merchant_order_id)) {
      orderId = body.merchant_order_id;
    }
    context = sanitizeAnalyticsContext(body.context);
  } catch {
    // fall through: no kind
  }
  if (!kind) return errorResponse(400, "invalid_body", "kind is required");

  const stored = { ...(context ?? {}), ...requestSignal(c.req.raw) };
  const sql = getDb(env);
  try {
    await sql`
      INSERT INTO checkout_events (user_id, merchant_order_id, kind, context)
      VALUES (${sub}, ${orderId}, ${kind},
              ${Object.keys(stored).length ? JSON.stringify(stored) : null}::text::jsonb)
    `;
    return c.json({ ok: true });
  } catch (err) {
    console.error("[me/checkout-event] DB error:", err);
    return errorResponse(500, "server_error", "Internal server error");
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }
}

const CHECKOUT_KIND_RE = /^[a-z0-9_:]{1,60}$/;

/** `DKS_<tag>_<8 hex>_<base36>_<4 hex>` from `buildMerchantOrderId` -> shape only, never a lookup. */
const ORDER_ID_RE = /^[A-Za-z0-9_-]{1,63}$/;

/** The app's `?source=` values (apply, share, ringtone_set, trial_nudge, settings, push, …). */
const PAYWALL_SOURCE_RE = /^[a-z_]{1,40}$/;

/** A campaign id is always a uuid -> anything else is a malformed payload, never a lookup. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
