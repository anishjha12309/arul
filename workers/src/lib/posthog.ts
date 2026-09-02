/**
 * The ONLY server-side analytics sink. GA4 and Meta server reporting are deleted -> never re-add either here.
 *
 * The FIRST trial->paid conversion settles app-closed (cron or S2S webhook) -> no client can ever emit it
 * Without this the PostHog journey ended at `trial_started` -> the funnel had no paid endpoint at all
 * SERVER-side only -> the client allow-list `postHogAllowedEvents` is unchanged, pinned by analytics_gating_test.dart
 * Join key is distinct_id = users.id -> the app identifies PostHog with the Neon user id at login
 * Capture API: POST {host}/i/v0/e with api_key + event + distinct_id (posthog.com/docs/api/capture)
 * It answers 200 even for events it DROPS -> the KV mark means "call accepted", never "event ingested"
 * PostHog dedupes on the whole key [timestamp, distinct_id, event, uuid] -> a deterministic uuid alone is not enough
 * So callers pass `occurredAt` — the transition's own RETURNING `updated_at` -> a resend keeps the same key
 * Stamping a resend with the wall clock would mint a new key every time -> `now()` is only the last-resort fallback
 * Fail-open EVERYWHERE -> analytics must never throw into, or block, a billing transition
 */

import type { Env } from "../env.js";

const DEFAULT_HOST = "https://us.i.posthog.com";

interface FirstConversion {
  userId: string;
  /** Merchant order id of the settled debit (DKS_…_R…). */
  transactionId: string;
  /** Paise. Falls back to ₹199 when the payload omitted it. */
  amountPaise?: number | null;
  /** The row's `updated_at` as RETURNED by the UPDATE -> stable across a resend -> this is what makes `uuid` dedupe. */
  occurredAt?: Date | string | null;
}

const FALLBACK_AMOUNT_PAISE = 19900;

/** Order ids never recur -> 30 days outlives every webhook redelivery and the cron reconcile window. */
const DEDUPE_TTL_SECONDS = 30 * 24 * 60 * 60;

/** An unparseable timestamp falls through to now -> a bad instant must cost precision, never the event. */
function eventTimestamp(occurredAt: Date | string | null | undefined): string {
  if (occurredAt instanceof Date && !Number.isNaN(occurredAt.getTime())) {
    return occurredAt.toISOString();
  }
  if (typeof occurredAt === "string") {
    const parsed = new Date(occurredAt);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString();
  }
  return new Date().toISOString();
}

/** UUID-shaped and derived from (event, seed) -> a KV eventual-consistency double-send carries the SAME uuid. */
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
 * Capture one settled FIRST trial->paid debit as `subscription_active`.
 * The prior-status === 'trialing' gate is the CALLER's -> this function does not re-check it
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
        timestamp: eventTimestamp(purchase.occurredAt),
        // plan/order_id/value mirror the client convention -> the two sources aggregate as one event
        // $lib marks the reporter -> server rows stay separable in analysis
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

/** Every value is a channel that WRITES status='cancelled' onto a LIVE (trialing/active/paused) row:
 *   user_cancel          POST /payments/cancel — Manage Subscription in the app
 *   account_deleted      DELETE /me revoked a live mandate before deleting the user
 *   revoked_at_phonepe   the user revoked in their UPI app -> seen by the cron or /payments/status
 *   rejected_by_phonepe  PhonePe permanently rejected the notify -> the mandate is unusable
 *   webhook_revoked      a subscription.revoked / subscription.cancelled webhook
 * A "restore" write is NOT a cancel -> the mandate was already gone before that re-setup -> nothing new was lost */
export type SubscriptionCancelReason =
  | "user_cancel"
  | "account_deleted"
  | "revoked_at_phonepe"
  | "rejected_by_phonepe"
  | "webhook_revoked";

interface SubscriptionCancel {
  userId: string;
  /** DKS_S_… of the mandate that ended; null only when account deletion found no row.
   * One event per MANDATE -> a resubscribe mints a new id -> cancelling that one is a new event. */
  merchantSubId: string | null;
  reason: SubscriptionCancelReason;
  /** Row status BEFORE the write: 'trialing' | 'active' | 'paused' | … */
  priorStatus: string | null;
  /** The cancel write's own RETURNED `updated_at` — see FirstConversion.occurredAt.
   * Optional because account deletion leaves no row to return one. */
  occurredAt?: Date | string | null;
}

/** A cancel is a real loss only from these -> an already-cancelled/expired/pending row cancelling again is not an event. */
const LIVE_STATUSES = new Set(["trialing", "active", "paused"]);

/**
 * Capture `subscription_cancel` — the churn counterpart of `subscription_active`.
 *
 * Three of the five channels above fire app-closed -> no client can emit this -> server-side only
 * Non-live priors are dropped HERE -> no call site has to remember the rule -> callers just pass priorStatus
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
        timestamp: eventTimestamp(cancel.occurredAt),
        properties: {
          plan: "monthly",
          reason: cancel.reason,
          prior_status: cancel.priorStatus,
          // true = they left before ever paying ₹199 (trial churn); false = a paying subscriber stopped
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
