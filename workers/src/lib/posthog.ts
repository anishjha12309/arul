/**
 * Server-side PostHog `subscription_active` capture.
 *
 * WHY THIS EXISTS: the FIRST trial→paid conversion settles app-closed (hourly
 * cron / S2S webhook), so the PostHog journey had no paid endpoint at all —
 * `trial_started` was the last thing it ever saw. Re-adding the paid event is
 * an owner decision (2026-08-24) reversing part of the 2026-08-18 five-event
 * trim: the funnel needed its real endpoint back, and the volume is single
 * digits per day. It comes back SERVER-side only — the client allow-list
 * (`postHogAllowedEvents`, pinned by test/core/analytics_gating_test.dart) is
 * unchanged, because the client-observable `subscription_active` (repeat
 * subscriber paying at setup) is a different purchase and stays GA4/Meta-only.
 *
 * Join key: distinct_id = users.id — the app identifies PostHog with the Neon
 * user id at login (api_auth_service.dart), verified against production
 * 2026-08-24 (sampled trialing users' ids all resolve as PostHog persons).
 *
 * Contract per PostHog capture API (posthog.com/docs/api/capture, fetched
 * 2026-08-24): POST {host}/i/v0/e with api_key + event + distinct_id;
 * properties/timestamp optional; answers 200 even for events it drops, so the
 * KV mark is "call accepted", not "event ingested" — the event's presence in
 * PostHog is the real verification. `uuid` is sent deterministically from the
 * transaction id as a second dedup layer under the KV mark.
 *
 * Fail-open EVERYWHERE, mirroring lib/ga4.ts: never throw, never block a
 * billing transition; missing POSTHOG_API_KEY logs and skips.
 */

import type { Env } from "../env.js";

const DEFAULT_HOST = "https://us.i.posthog.com";

interface FirstConversion {
  userId: string;
  /** Merchant order id of the settled debit (DKS_…_R…). */
  transactionId: string;
  /** Paise. Falls back to ₹199 when the payload omitted it. */
  amountPaise?: number | null;
}

const FALLBACK_AMOUNT_PAISE = 19900;

/** Same TTL rationale as ga4.ts: order ids never recur; 30 days outlives every
 * webhook redelivery + cron reconcile window. */
const DEDUPE_TTL_SECONDS = 30 * 24 * 60 * 60;

/** Deterministic UUID-shaped id from (event, seed), so even a KV-eventual-
 * consistency double-send carries the same uuid into PostHog. */
async function deterministicUuid(event: string, seed: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`arul:${event}:${seed}`),
  );
  const b = new Uint8Array(digest);
  b[6] = (b[6] & 0x0f) | 0x40; // version nibble
  b[8] = (b[8] & 0x3f) | 0x80; // variant bits
  const hex = [...b.slice(0, 16)].map((x) => x.toString(16).padStart(2, "0")).join("");
  return (
    `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-` +
    `${hex.slice(16, 20)}-${hex.slice(20, 32)}`
  );
}

/**
 * Capture one settled FIRST trial→paid debit as `subscription_active`.
 * Caller is responsible for the prior-status === 'trialing' gate.
 */
export async function reportPostHogFirstConversion(
  env: Env,
  purchase: FirstConversion,
): Promise<void> {
  try {
    if (!env.POSTHOG_API_KEY) {
      console.log("[posthog] POSTHOG_API_KEY not configured — skipping subscription_active");
      return;
    }

    const dedupeKey = `ph:subscription_active:${purchase.transactionId}`;
    if (await env.KV.get(dedupeKey)) {
      console.log(
        `[posthog] subscription_active ${purchase.transactionId} already reported — skipping`,
      );
      return;
    }

    const amountPaise =
      typeof purchase.amountPaise === "number" && purchase.amountPaise > 0
        ? purchase.amountPaise
        : FALLBACK_AMOUNT_PAISE;

    const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/+$/, "");
    const res = await fetch(`${host}/i/v0/e`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_key: env.POSTHOG_API_KEY,
        event: "subscription_active",
        distinct_id: purchase.userId,
        uuid: await deterministicUuid("subscription_active", purchase.transactionId),
        timestamp: new Date().toISOString(),
        // Property names match the client-side conversion convention
        // (premium_purchase_provider._trackConversion): plan/order_id/value.
        // $lib marks the reporter so server rows are separable in analysis.
        properties: {
          plan: "monthly",
          order_id: purchase.transactionId,
          value: amountPaise / 100,
          currency: "INR",
          $lib: "arul-worker",
        },
      }),
    });

    if (res.ok) {
      console.log(
        `[posthog] subscription_active captured txn=${purchase.transactionId} ` +
        `user=${purchase.userId} value=₹${amountPaise / 100}`,
      );
      await env.KV.put(dedupeKey, "1", { expirationTtl: DEDUPE_TTL_SECONDS });
    } else {
      console.error(
        `[posthog] capture rejected (HTTP ${res.status}) for txn=${purchase.transactionId}: ` +
        (await res.text()),
      );
    }
  } catch (err) {
    // Analytics must never break a billing transition.
    console.error(
      `[posthog] subscription_active failed for txn=${purchase.transactionId}:`,
      err,
    );
  }
}

/** Why a subscription stopped. Every value is a channel that WRITES
 * status='cancelled' on a live (trialing/active/paused) row:
 *   user_cancel          POST /payments/cancel (Manage Subscription in the app)
 *   account_deleted      DELETE /me revoked a live mandate before deleting the user
 *   revoked_at_phonepe   PhonePe reported the mandate CANCELLED/REVOKED (user did
 *                        it in their UPI app) — seen by the cron or /payments/status
 *   rejected_by_phonepe  PhonePe permanently rejected the notify (mandate unusable)
 *   webhook_revoked      subscription.revoked / subscription.cancelled webhook
 * NOT a cancel: the "restore" writes that put a still-paid row back to
 * 'cancelled' after a failed/abandoned RE-setup — the user's mandate was
 * already gone before that attempt, so nothing new was lost there. */
export type SubscriptionCancelReason =
  | "user_cancel"
  | "account_deleted"
  | "revoked_at_phonepe"
  | "rejected_by_phonepe"
  | "webhook_revoked";

interface SubscriptionCancel {
  userId: string;
  /** DKS_S_… of the mandate that ended; null only on the account-deletion
   * path when the row had none. One event per mandate — a resubscribe mints a
   * new id, so a later cancel of THAT mandate is a new event. */
  merchantSubId: string | null;
  reason: SubscriptionCancelReason;
  /** Row status before the write: 'trialing' | 'active' | 'paused' | … */
  priorStatus: string | null;
}

/** Statuses from which a cancel is a real loss of a live subscription. An
 * already-cancelled/expired/pending row cancelling again is not an event. */
const LIVE_STATUSES = new Set(["trialing", "active", "paused"]);

/**
 * Capture `subscription_cancel` — the churn counterpart of
 * `subscription_active`, added at the owner's request (2026-08-25, "add both
 * subscription_started & subscription_cancel in posthog"). Server-side only,
 * like subscription_active: three of the five channels above fire app-closed.
 * Callers pass the row's PRIOR status; non-live priors are dropped here so no
 * call site has to remember the rule.
 */
export async function reportPostHogSubscriptionCancel(
  env: Env,
  cancel: SubscriptionCancel,
): Promise<void> {
  try {
    if (!env.POSTHOG_API_KEY) {
      console.log("[posthog] POSTHOG_API_KEY not configured — skipping subscription_cancel");
      return;
    }
    if (!cancel.priorStatus || !LIVE_STATUSES.has(cancel.priorStatus)) {
      console.log(
        `[posthog] subscription_cancel skipped — prior status ${cancel.priorStatus ?? "null"} ` +
        `is not a live subscription (user=${cancel.userId}, reason=${cancel.reason})`,
      );
      return;
    }

    const seed = cancel.merchantSubId ?? `user:${cancel.userId}`;
    const dedupeKey = `ph:subscription_cancel:${seed}`;
    if (await env.KV.get(dedupeKey)) {
      console.log(`[posthog] subscription_cancel ${seed} already reported — skipping`);
      return;
    }

    const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/+$/, "");
    const res = await fetch(`${host}/i/v0/e`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_key: env.POSTHOG_API_KEY,
        event: "subscription_cancel",
        distinct_id: cancel.userId,
        uuid: await deterministicUuid("subscription_cancel", seed),
        timestamp: new Date().toISOString(),
        properties: {
          plan: "monthly",
          reason: cancel.reason,
          prior_status: cancel.priorStatus,
          // true = the user left before ever paying ₹199 (trial churn);
          // false = a paying subscriber stopped.
          during_trial: cancel.priorStatus === "trialing",
          merchant_subscription_id: cancel.merchantSubId,
          $lib: "arul-worker",
        },
      }),
    });

    if (res.ok) {
      console.log(
        `[posthog] subscription_cancel captured user=${cancel.userId} sub=${seed} ` +
        `reason=${cancel.reason} prior=${cancel.priorStatus}`,
      );
      await env.KV.put(dedupeKey, "1", { expirationTtl: DEDUPE_TTL_SECONDS });
    } else {
      console.error(
        `[posthog] subscription_cancel rejected (HTTP ${res.status}) for ${seed}: ` +
        (await res.text()),
      );
    }
  } catch (err) {
    // Analytics must never break a billing transition.
    console.error(`[posthog] subscription_cancel failed for user=${cancel.userId}:`, err);
  }
}
