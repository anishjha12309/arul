/**
 * Server-side GA4 `purchase` reporting via the Measurement Protocol.
 *
 * WHY THIS EXISTS: trial→paid conversion and every monthly renewal settle in
 * the hourly autopay cron or the S2S webhook — the app is closed, so no client
 * event can ever exist for them. Without this, GA4/Google Ads `purchase`
 * under-reports all trial-originated revenue. The app-open flows (repeat
 * subscriber paying ₹199 at setup) are logged CLIENT-side
 * (google_analytics_service.dart) and deliberately NOT here — the split by
 * settle location is what prevents double counting.
 *
 * Join key: the Firebase app_instance_id the app uploads on /auth/login and
 * /payments/initiate (users.app_instance_id). MP events sent with it join the
 * user's GA4 stream and inherit their ad attribution.
 *
 * Fail-open EVERYWHERE: this function must never throw and never block a
 * billing state transition — a lost analytics event is noise, a lost debit
 * grant is a support ticket. Missing config (GA4_API_SECRET / GA4_FIREBASE_APP_ID
 * unset) just logs and skips, so tests and un-configured environments are
 * unaffected.
 *
 * NOTE: /mp/collect answers 204 even for payloads it silently drops (bad
 * api_secret included). Validation lives at /debug/mp/collect — use
 * workers/tools/ga4-mp-validate.mjs when wiring a new property.
 */

import type { Env } from "../env.js";
import type { getDb } from "./db.js";

const MP_ENDPOINT = "https://www.google-analytics.com/mp/collect";

/** GA4 app_instance_id — exactly 32 lowercase hex chars. Shared by the
 * /auth/login and /payments/initiate handlers to validate the uploaded value. */
export const APP_INSTANCE_ID_RE = /^[a-f0-9]{32}$/;

/** Sanitize + validate a client-supplied app_instance_id; null when unusable. */
export function normalizeAppInstanceId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim().toLowerCase();
  return APP_INSTANCE_ID_RE.test(v) ? v : null;
}

interface ServerPurchase {
  userId: string;
  /** Merchant order id of the settled debit (DKS_…_R…). Used as GA4
   * transaction_id, so the webhook's order+transaction event pair and a
   * cron/webhook double-settle all collapse to one purchase. */
  transactionId: string;
  /** Paise. Falls back to ₹199 when the payload omitted it. */
  amountPaise?: number | null;
}

const FALLBACK_AMOUNT_PAISE = 19900;

/** KV mark TTL — order ids never recur across cycles; 30 days outlives every
 * webhook redelivery + cron reconcile window. */
const DEDUPE_TTL_SECONDS = 30 * 24 * 60 * 60;

/**
 * Report one settled debit as a GA4 `purchase`.
 *
 * Dedupes on transactionId via KV BEFORE any DB read: PhonePe emits both
 * `…redemption.order.completed` and `…redemption.transaction.completed` for the
 * same order, and the cron can settle a debit the webhook also delivers. GA4
 * additionally dedupes purchases on transaction_id, but relying on that alone
 * would still bill two KV-less MP calls per debit.
 */
export async function reportServerPurchase(
  env: Env,
  sql: ReturnType<typeof getDb>,
  purchase: ServerPurchase,
): Promise<void> {
  try {
    if (!env.GA4_API_SECRET || !env.GA4_FIREBASE_APP_ID) {
      console.log(
        "[ga4] GA4_API_SECRET/GA4_FIREBASE_APP_ID not configured — skipping purchase report",
      );
      return;
    }

    const dedupeKey = `ga4:purchase:${purchase.transactionId}`;
    if (await env.KV.get(dedupeKey)) {
      console.log(`[ga4] purchase ${purchase.transactionId} already reported — skipping`);
      return;
    }

    const rows = (await sql`
      SELECT app_instance_id FROM users WHERE id = ${purchase.userId} LIMIT 1
    `) as unknown as { app_instance_id: string | null }[];
    const appInstanceId = normalizeAppInstanceId(rows[0]?.app_instance_id);
    if (!appInstanceId) {
      // Pre-upload installs (build < 1.0.0+28) have no id — expected, not an error.
      console.log(
        `[ga4] user ${purchase.userId} has no app_instance_id — purchase ` +
        `${purchase.transactionId} not reported (Neon remains revenue truth)`,
      );
      return;
    }

    const amountPaise =
      typeof purchase.amountPaise === "number" && purchase.amountPaise > 0
        ? purchase.amountPaise
        : FALLBACK_AMOUNT_PAISE;

    const url =
      `${MP_ENDPOINT}?firebase_app_id=${encodeURIComponent(env.GA4_FIREBASE_APP_ID)}` +
      `&api_secret=${encodeURIComponent(env.GA4_API_SECRET)}`;

    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        app_instance_id: appInstanceId,
        events: [
          {
            name: "purchase",
            params: {
              currency: "INR",
              value: amountPaise / 100,
              transaction_id: purchase.transactionId,
            },
          },
        ],
      }),
    });

    // 2xx is all MP ever answers for accepted-or-silently-dropped payloads;
    // non-2xx means the request itself was malformed — log it loudly.
    if (res.ok) {
      console.log(
        `[ga4] purchase reported txn=${purchase.transactionId} value=₹${amountPaise / 100}`,
      );
      await env.KV.put(dedupeKey, "1", { expirationTtl: DEDUPE_TTL_SECONDS });
    } else {
      console.error(
        `[ga4] MP request rejected (HTTP ${res.status}) for txn=${purchase.transactionId}`,
      );
    }
  } catch (err) {
    // Analytics must never break a billing transition.
    console.error(`[ga4] purchase report failed for txn=${purchase.transactionId}:`, err);
  }
}
