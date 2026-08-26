/**
 * Server-side Meta `Subscribe` reporting via the Conversions API (app events).
 *
 * WHY THIS EXISTS: the FIRST trial→paid conversion settles in the hourly
 * autopay cron or the S2S webhook — the app is closed, so the client-side
 * Meta Subscribe (MetaAnalyticsService → logSubscribe) can never fire for it.
 * Meta's algorithm was bidding on campaigns without ever seeing a subscription
 * event (18 conversions 20–24 Aug 2026, zero Subscribe events in the dataset).
 *
 * Scope is deliberately FIRST CONVERSION ONLY (owner's call, 2026-08-24):
 * callers gate on the row's prior status being 'trialing'. Renewals stay out —
 * Meta optimises acquisition, and a renewal says nothing about the ad click
 * that acquired the user. (GA4 lib/ga4.ts still reports every debit; its scope
 * is different on purpose.) The repeat-subscriber ₹199 setup settles app-open
 * and is reported CLIENT-side as Subscribe — the settle-location split is what
 * prevents double counting, exactly as with GA4 purchase.
 *
 * Contract per Meta's Conversions API server-event reference (fetched
 * 2026-08-25): POST https://graph.facebook.com/v25.0/{DATASET_ID}/events;
 * `action_source` is REQUIRED and must be accurate — this event is sent as
 * **`system_generated`**, which Meta defines verbatim as "Conversion happened
 * automatically, for example, a subscription renewal that's set to auto-pay
 * each month", and the same reference states every action_source enables
 * measurement, audiences AND ad optimisation. `action_source: "app"` was tried
 * first and REJECTED live (2026-08-25, error_subcode 2804043 "Invalid extended
 * device info parameter"): app events require an `extinfo` with a real OS
 * version, which a server settling an app-closed debit does not have, and
 * inventing one would make the payload a lie. Three first conversions bounced
 * before the switch. event_id is the cross-channel dedup key (same event_name +
 * event_id as an SDK event collapses to one). user_data needs ≥1 of
 * em/ph/external_id/fbp/fbc — em/external_id are SHA-256 hex of the lowercased
 * input.
 *
 * Match keys:
 *   em          (users.email — every user has one, Google sign-in)
 *   external_id (users.id — the same value the app feeds setUserID, which the
 *                SDK hashes, so the hashed forms line up)
 *   fn / ln     (users.display_name from Google, split on whitespace: first
 *                token → fn, last token → ln when there are two or more).
 *                Normalised EXACTLY as Meta's own capi-param-builder does
 *                (github.com/facebook/capi-param-builder, nodejs
 *                stringUtil.getNormalizedName, read 2026-08-25): lowercase,
 *                strip ASCII punctuation + whitespace, then SHA-256. Events
 *                Manager listed fn/ln as +15% EMQ each for this dataset's
 *                Subscribe. Name is the ONLY extra key that adds no new data
 *                type and no new recipient under Play's Data safety rules —
 *                IP / user agent / IP-derived city are Meta's bigger levers but
 *                each is a new declaration (Google: IP used to determine
 *                location must be declared; ad-measurement use is never
 *                "ephemeral"), so they are deliberately NOT sent.
 * users.meta_anon_id (the SDK's install GUID, uploaded at login/initiate from
 * builds that carry meta_anon_id.dart) is the key for a future TRUE app-event
 * path — it needs real device extinfo alongside it, so it is stored, not sent.
 *
 * Fail-open EVERYWHERE, mirroring lib/ga4.ts: never throw, never block a
 * billing transition; missing config (META_DATASET_ID / META_CAPI_ACCESS_TOKEN
 * unset) logs and skips, so tests and un-configured environments are
 * unaffected. The KV mark `meta:subscribe:<txn>` is written ONLY on a 2xx
 * (Graph answers 2xx only when it accepted the batch, a 4xx with an error
 * object otherwise), so the mark's presence proves delivery —
 * same verification pattern as `ga4:purchase:<txn>` (docs/google-ads.md).
 * Payload-shape validation without touching prod: tools/meta-capi-validate.mjs
 * (test_event_code — lands in Events Manager's Test Events tab only).
 */

import type { Env } from "../env.js";
import type { getDb } from "./db.js";

const GRAPH_ENDPOINT = "https://graph.facebook.com/v25.0";

/** Meta SDK anonymous app device GUID — Android emits "XZ" + UUID. */
const META_ANON_ID_RE = /^[A-Za-z0-9-]{8,64}$/;

/** Meta's STRIP_WHITESPACE_AND_PUNCTUATION_REGEX, verbatim from
 * capi-param-builder nodejs/src/piiUtil/commonUtil.js. */
const META_NAME_STRIP_RE =
  /[!"#\$%&'\(\)\*\+,\-\.\/:;<=>\?@ \[\\\]\^_`\{\|\}~\s]+/g;

/** Normalise a name part the way Meta's param builder does before hashing:
 * lowercase, drop ASCII punctuation and whitespace. Non-Latin scripts (Tamil,
 * Devanagari…) pass through untouched, as in the reference implementation.
 * Returns null when nothing is left. */
export function normalizeMetaName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.toLowerCase().replace(META_NAME_STRIP_RE, "");
  return v.length > 0 ? v : null;
}

/** Google display_name → { fn, ln }: first whitespace token is the first
 * name, the LAST token the surname (middle names dropped); a single token is
 * fn only. Both already normalised; null when unusable. */
export function splitDisplayName(
  value: unknown,
): { fn: string | null; ln: string | null } {
  if (typeof value !== "string") return { fn: null, ln: null };
  const parts = value.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { fn: null, ln: null };
  const fn = normalizeMetaName(parts[0]);
  const ln = parts.length > 1 ? normalizeMetaName(parts[parts.length - 1]) : null;
  return { fn, ln };
}

/** Sanitize + validate a client-supplied Meta anon id; null when unusable. */
export function normalizeMetaAnonId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  return META_ANON_ID_RE.test(v) ? v : null;
}

interface FirstConversion {
  userId: string;
  /** Merchant order id of the settled debit (DKS_…_R…) — the event_id, so a
   * cron/webhook double-settle collapses to one Subscribe. */
  transactionId: string;
  /** Paise. Falls back to ₹199 when the payload omitted it. */
  amountPaise?: number | null;
}

const FALLBACK_AMOUNT_PAISE = 19900;

/** Same TTL rationale as ga4.ts: order ids never recur; 30 days outlives every
 * webhook redelivery + cron reconcile window. */
const DEDUPE_TTL_SECONDS = 30 * 24 * 60 * 60;

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Report one settled FIRST trial→paid debit as a Meta `Subscribe` app event.
 * Caller is responsible for the prior-status === 'trialing' gate.
 */
export async function reportMetaFirstConversion(
  env: Env,
  sql: ReturnType<typeof getDb>,
  purchase: FirstConversion,
): Promise<void> {
  try {
    if (!env.META_DATASET_ID || !env.META_CAPI_ACCESS_TOKEN) {
      console.log(
        "[meta] META_DATASET_ID/META_CAPI_ACCESS_TOKEN not configured — skipping Subscribe report",
      );
      return;
    }

    const dedupeKey = `meta:subscribe:${purchase.transactionId}`;
    if (await env.KV.get(dedupeKey)) {
      console.log(`[meta] Subscribe ${purchase.transactionId} already reported — skipping`);
      return;
    }

    const rows = (await sql`
      SELECT email, display_name FROM users WHERE id = ${purchase.userId} LIMIT 1
    `) as unknown as { email: string | null; display_name: string | null }[];
    const email = rows[0]?.email?.trim().toLowerCase() ?? null;
    const { fn, ln } = splitDisplayName(rows[0]?.display_name);
    if (!email) {
      // Meta requires ≥1 customer information parameter it can match on.
      // external_id alone is accepted but matches nobody without a companion,
      // and every Arul user signs in with Google, so this is near-unreachable.
      console.log(
        `[meta] user ${purchase.userId} has no email — Subscribe ` +
        `${purchase.transactionId} not reported (Neon remains revenue truth)`,
      );
      return;
    }

    const amountPaise =
      typeof purchase.amountPaise === "number" && purchase.amountPaise > 0
        ? purchase.amountPaise
        : FALLBACK_AMOUNT_PAISE;

    const body = {
      data: [
        {
          event_name: "Subscribe",
          event_time: Math.floor(Date.now() / 1000),
          event_id: purchase.transactionId,
          action_source: "system_generated",
          user_data: {
            em: [await sha256Hex(email)],
            // The app calls setUserID(users.id) for advanced matching and the
            // SDK hashes it — hashing the same raw value makes the two line up.
            external_id: [await sha256Hex(purchase.userId)],
            ...(fn ? { fn: [await sha256Hex(fn)] } : {}),
            ...(ln ? { ln: [await sha256Hex(ln)] } : {}),
          },
          custom_data: {
            currency: "INR",
            value: amountPaise / 100,
            order_id: purchase.transactionId,
          },
        },
      ],
    };

    const url =
      `${GRAPH_ENDPOINT}/${encodeURIComponent(env.META_DATASET_ID)}/events` +
      `?access_token=${encodeURIComponent(env.META_CAPI_ACCESS_TOKEN)}`;

    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });

    // Graph answers 200 + {"events_received":N} on acceptance and a 4xx with an
    // error object when the payload/token is bad — surface the body either way.
    const resBody = await res.text();
    if (res.ok) {
      console.log(
        `[meta] Subscribe reported txn=${purchase.transactionId} ` +
        `value=₹${amountPaise / 100} matched=em+external_id` +
        `${fn ? "+fn" : ""}${ln ? "+ln" : ""} response=${resBody}`,
      );
      await env.KV.put(dedupeKey, "1", { expirationTtl: DEDUPE_TTL_SECONDS });
    } else {
      console.error(
        `[meta] CAPI rejected (HTTP ${res.status}) txn=${purchase.transactionId}: ${resBody}`,
      );
    }
  } catch (err) {
    // Analytics must never break a billing transition.
    console.error(`[meta] Subscribe report failed for txn=${purchase.transactionId}:`, err);
  }
}
