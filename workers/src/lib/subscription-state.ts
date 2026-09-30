/**
 * The subscription row's shared transitions. The webhook, /payments/status, initiate and the hourly sweeps all
 * write through these, so a grant or a release has ONE copy and the surfaces cannot disagree (docs/phonepe.md).
 * Every `where` fragment names the row through the alias `s`.
 */

import type postgres from "postgres";
import type { Env } from "../env.js";
import { getSubscriptionStatus } from "./phonepe.js";
import {
  reportPostHogFirstConversion,
  reportPostHogSubscriptionCancel,
  type SubscriptionCancelReason,
} from "./posthog.js";
import { OFFER_PRICE_PAISE, STANDARD_PRICE_PAISE } from "./pricing.js";
import { grantReferralReward } from "./referral.js";

type Sql = postgres.Sql;
type Fragment = postgres.PendingQuery<postgres.Row[]>;

/**
 * Free-trial length. The ₹2 PENNY_DROP only AUTHORIZES the mandate — the trial itself is ours.
 * It is also the debit clock -> next_debit_at = now + this -> the paywall copy must say the same number
 */
export const TRIAL_MS = 24 * 60 * 60 * 1000;

/** PhonePe refuses a debit inside 24 h of its notice -> a switched row's first ₹99 debit is at least this far out. */
const SWITCH_NOTICE_SLIDE = "25 hours";

/**
 * Decision 5's eligibility over aliases `s` (subscriptions) and `u` (users), shared by GET /me and initiate.
 * NOT `notified_at IS NULL`: Pass A notifies a 1-day trial minutes after it starts, and autoDebit:false means a
 * notified order moves no money until Pass B redeems it at next_debit_at -> "not due within the hour" is the guard
 */
export function cancelOfferEligible(sql: Sql): Fragment {
  return sql`(
    s.status IN ('trialing', 'active')
    AND s.current_period_end > now()
    AND s.merchant_subscription_id IS NOT NULL
    AND s.next_debit_at > now() + interval '1 hour'
    AND s.superseded_mandate_id IS NULL
    AND s.price_paise = ${STANDARD_PRICE_PAISE}
    AND u.cancel_offer_at IS NULL
  )`;
}

export interface ReleasedClaim {
  user_id: string;
  status: string;
  merchant_subscription_id: string | null;
  /** The unapproved id the claim pointed at -> the caller may revoke it. */
  released_mandate_id: string | null;
  was_offer: boolean;
}

/**
 * Hand a `pending` claim back: a parked mandate wins and becomes live again at its own price, the ladder resumes where
 * it stood; with nothing parked, a live period restores `cancelled`, else `expired`. A released cancel_99 keeps its
 * ₹99 id in offer_mandate_id so the sweep can honour a late approval
 */
export async function releaseClaim(sql: Sql, where: Fragment): Promise<ReleasedClaim[]> {
  return (await sql`
    UPDATE subscriptions AS s
    SET status                   = CASE
                                       -- A parked mandate is still billing -> hand the row back to it, the ladder resumes where it stood
                                       WHEN s.superseded_mandate_id IS NOT NULL
                                       THEN CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end
                                                 THEN 'active' ELSE 'trialing' END
                                       ELSE CASE WHEN s.current_period_end IS NOT NULL AND s.current_period_end > now()
                                                 THEN 'cancelled' ELSE 'expired' END
                                       END,
        merchant_subscription_id = COALESCE(s.superseded_mandate_id, s.merchant_subscription_id),
        price_paise              = CASE WHEN s.superseded_mandate_id IS NOT NULL
                                        THEN COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE})
                                        ELSE s.price_paise END,
        offer_mandate_id         = CASE WHEN s.offer_switch THEN s.merchant_subscription_id ELSE s.offer_mandate_id END,
        offer_switch             = false,
        superseded_mandate_id    = NULL,
        superseded_price_paise   = NULL,
        updated_at               = now()
    FROM subscriptions AS prior
    WHERE ${where}
      AND prior.id = s.id
      AND s.status = 'pending'
    RETURNING s.user_id, s.status, s.merchant_subscription_id,
              prior.merchant_subscription_id AS released_mandate_id, prior.offer_switch AS was_offer
  `) as unknown as ReleasedClaim[];
}

export interface SetupGrant {
  kind: "switch" | "grant";
  user_id: string;
  status: string;
  price_paise: number | string;
  /** The mandate this grant replaced -> revoke it off the response path. */
  stale_mandate_id: string | null;
}

/**
 * A completed setup on a `pending` row -> the offer switch FIRST, then the ordinary grant. `AND status = 'pending'`
 * is LOAD-BEARING in both: the webhook and the status poll run this for the same order and share no dedupe key, and
 * the loser must find nothing to grant rather than re-read trial_end and hand out a paid month
 */
export async function grantCompletedSetup(
  sql: Sql,
  where: Fragment,
  phonepeSubId: string | null,
): Promise<SetupGrant | null> {
  return (await grantOfferSwitch(sql, where, phonepeSubId)) ?? (await grantSetup(sql, where, phonepeSubId));
}

/**
 * The ₹2 check of a cancel_99 switch is NOT a paid month: the row goes back to the status it had, keeps its paid
 * period, and its first ₹99 debit lands no earlier than a fresh 24 h notice allows (premium moves with it, and a
 * trial's trial_end too so it still reads as unconverted). No debit stamps, no referral reward, no subscription_active
 */
async function grantOfferSwitch(
  sql: Sql,
  where: Fragment,
  phonepeSubId: string | null,
): Promise<SetupGrant | null> {
  const rows = (await sql`
    WITH g AS (
      UPDATE subscriptions AS s
      SET status                  = CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end
                                         THEN 'active' ELSE 'trialing' END,
          phonepe_subscription_id = COALESCE(${phonepeSubId}, s.phonepe_subscription_id),
          next_debit_at           = GREATEST(s.next_debit_at, now() + ${SWITCH_NOTICE_SLIDE}::interval),
          current_period_end      = GREATEST(s.current_period_end, s.next_debit_at,
                                             now() + ${SWITCH_NOTICE_SLIDE}::interval),
          trial_end               = CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end
                                         THEN s.trial_end
                                         ELSE GREATEST(s.current_period_end, s.next_debit_at,
                                                       now() + ${SWITCH_NOTICE_SLIDE}::interval) END,
          notified_at             = NULL,
          -- The parked mandate's order goes with it: a legacy order left on an hsr row names two merchants
          redemption_order_id     = NULL,
          offer_switch            = false,
          offer_mandate_id        = NULL,
          superseded_mandate_id   = NULL,
          superseded_price_paise  = NULL,
          updated_at              = now()
      FROM subscriptions AS prior
      WHERE ${where}
        AND prior.id = s.id
        AND s.status = 'pending'
        AND s.offer_switch
      RETURNING s.user_id, s.status, s.price_paise, prior.superseded_mandate_id AS stale_mandate_id
    ),
    stamp AS (
      UPDATE users SET cancel_offer_at = COALESCE(users.cancel_offer_at, now())
      FROM g WHERE users.id = g.user_id
    )
    SELECT * FROM g
  `) as unknown as Omit<SetupGrant, "kind">[];
  return rows[0] ? { kind: "switch", ...rows[0] } : null;
}

/** The ELSE branch is itself a ₹199 TRANSACTION debit -> the three debit-tracking columns move on it and ONLY on it. */
async function grantSetup(
  sql: Sql,
  where: Fragment,
  phonepeSubId: string | null,
): Promise<SetupGrant | null> {
  const trialEnd = new Date(Date.now() + TRIAL_MS).toISOString();
  const paidEnd = addOneMonth(new Date()).toISOString();
  const rows = (await sql`
    UPDATE subscriptions AS s
    SET status                   = CASE WHEN s.trial_end IS NULL THEN 'trialing' ELSE 'active' END,
        phonepe_subscription_id  = COALESCE(${phonepeSubId}, s.phonepe_subscription_id),
        trial_end                = COALESCE(s.trial_end, ${trialEnd}),
        current_period_end       = CASE WHEN s.trial_end IS NULL
                                        THEN ${trialEnd}::timestamptz ELSE ${paidEnd}::timestamptz END,
        next_debit_at            = CASE WHEN s.trial_end IS NULL
                                        THEN ${trialEnd}::timestamptz ELSE ${paidEnd}::timestamptz END,
        notified_at              = NULL,
        retry_count              = 0,
        first_debit_at           = CASE WHEN s.trial_end IS NULL THEN s.first_debit_at
                                        ELSE COALESCE(s.first_debit_at, now()) END,
        debit_count              = CASE WHEN s.trial_end IS NULL THEN s.debit_count ELSE s.debit_count + 1 END,
        paid_paise               = CASE WHEN s.trial_end IS NULL THEN s.paid_paise
                                        ELSE s.paid_paise + s.price_paise END,
        superseded_mandate_id    = NULL,
        superseded_price_paise   = NULL,
        updated_at               = now()
    FROM subscriptions AS prior
    WHERE ${where}
      AND prior.id = s.id
      AND s.status = 'pending'
      AND NOT s.offer_switch
    RETURNING s.user_id, s.status, s.price_paise, prior.superseded_mandate_id AS stale_mandate_id
  `) as unknown as Omit<SetupGrant, "kind">[];
  return rows[0] ? { kind: "grant", ...rows[0] } : null;
}

/**
 * The user approved ₹99 in their UPI app after we had already released the claim -> honour it while the row is still
 * on its ₹199 mandate and not due within the hour: park and grant in ONE statement. Null = not honoured; the caller
 * then revokes the ₹99 mandate
 */
export async function honourLateOfferApproval(
  sql: Sql,
  offerMandateId: string,
  phonepeSubId: string | null,
): Promise<SetupGrant | null> {
  const rows = (await sql`
    WITH g AS (
      UPDATE subscriptions AS s
      SET merchant_subscription_id = s.offer_mandate_id,
          phonepe_subscription_id  = ${phonepeSubId}::text,
          price_paise              = ${OFFER_PRICE_PAISE},
          next_debit_at            = GREATEST(s.next_debit_at, now() + ${SWITCH_NOTICE_SLIDE}::interval),
          current_period_end       = GREATEST(s.current_period_end, s.next_debit_at,
                                              now() + ${SWITCH_NOTICE_SLIDE}::interval),
          trial_end                = CASE WHEN s.trial_end IS NOT NULL AND s.current_period_end > s.trial_end
                                          THEN s.trial_end
                                          ELSE GREATEST(s.current_period_end, s.next_debit_at,
                                                        now() + ${SWITCH_NOTICE_SLIDE}::interval) END,
          notified_at              = NULL,
          redemption_order_id      = NULL,
          offer_mandate_id         = NULL,
          offer_switch             = false,
          updated_at               = now()
      FROM subscriptions AS prior
      WHERE s.offer_mandate_id = ${offerMandateId}
        AND prior.id = s.id
        AND s.status IN ('trialing', 'active')
        AND s.price_paise = ${STANDARD_PRICE_PAISE}
        AND s.superseded_mandate_id IS NULL
        AND s.current_period_end > now()
        AND s.next_debit_at > now() + interval '1 hour'
      RETURNING s.user_id, s.status, s.price_paise, prior.merchant_subscription_id AS stale_mandate_id
    ),
    stamp AS (
      UPDATE users SET cancel_offer_at = COALESCE(users.cancel_offer_at, now())
      FROM g WHERE users.id = g.user_id
    )
    SELECT * FROM g
  `) as unknown as Omit<SetupGrant, "kind">[];
  return rows[0] ? { kind: "switch", ...rows[0] } : null;
}

/** A mandate the switch grant could not revoke: never notified, so it cannot debit, but the user still sees it. */
export async function noteRevokeRetry(sql: Sql, userId: string, mandateId: string): Promise<void> {
  await sql`
    UPDATE subscriptions
    SET revoke_retry_mandate_id = ${mandateId},
        updated_at              = now()
    WHERE user_id = ${userId}
  `;
}

export interface HealedDebit {
  user_id: string;
  status: string;
  current_period_end: unknown;
  next_debit_at: unknown;
  merchant_subscription_id: string | null;
  price_paise: number | string;
  /** The claim's unapproved id when a parked mandate won -> the caller revokes it. */
  prior_mandate_id: string | null;
}

/**
 * A redemption order that COMPLETED on a row that never converted -> grant the paid month (the never-converted gate
 * stops a period being granted twice). The mandate that was debited is the live one, so a parked id wins over an
 * unapproved replacement. A mandate already revoked keeps the month as `cancelled` with no next debit. The CALLER
 * has read the order COMPLETED and revokes `prior_mandate_id`
 */
export async function healSettledDebit(
  env: Env,
  sql: Sql,
  where: Fragment,
  redemptionOrderId: string,
): Promise<HealedDebit | null> {
  const candidate = (await sql`
    SELECT COALESCE(s.superseded_mandate_id, s.merchant_subscription_id) AS mandate_id
    FROM subscriptions AS s
    WHERE ${where}
      AND s.redemption_order_id = ${redemptionOrderId}
      AND s.trial_end IS NOT NULL
      AND (s.current_period_end IS NULL OR s.current_period_end <= s.trial_end)
    LIMIT 1
  `) as unknown as { mandate_id: string | null }[];
  if (!candidate[0]) return null;

  // A failed read tells us nothing -> `active`, and Pass A parks a dead mandate at its next notify
  let ended = false;
  const mandateId = candidate[0].mandate_id;
  if (mandateId) {
    try {
      const st = await getSubscriptionStatus(env, mandateId);
      ended = st.state === "REVOKED" || st.state === "CANCELLED";
    } catch (err) {
      console.warn(`[heal] mandate status for ${mandateId} failed — granting as active:`, err);
    }
  }

  const nextEnd = addOneMonth(new Date()).toISOString();
  const healed = (await sql`
    UPDATE subscriptions AS s
    SET status                   = ${ended ? "cancelled" : "active"},
        merchant_subscription_id = COALESCE(s.superseded_mandate_id, s.merchant_subscription_id),
        price_paise              = CASE WHEN s.superseded_mandate_id IS NOT NULL
                                        THEN COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE})
                                        ELSE s.price_paise END,
        offer_mandate_id         = CASE WHEN s.offer_switch THEN s.merchant_subscription_id ELSE s.offer_mandate_id END,
        offer_switch             = false,
        superseded_mandate_id    = NULL,
        superseded_price_paise   = NULL,
        current_period_end       = ${nextEnd},
        next_debit_at            = ${ended ? null : nextEnd},
        notified_at              = NULL,
        retry_count              = 0,
        redemption_order_id      = NULL,
        first_debit_at           = COALESCE(s.first_debit_at, now()),
        debit_count              = s.debit_count + 1,
        paid_paise               = s.paid_paise + CASE WHEN s.superseded_mandate_id IS NOT NULL
                                                       THEN COALESCE(s.superseded_price_paise, ${STANDARD_PRICE_PAISE})
                                                       ELSE s.price_paise END,
        updated_at               = now()
    FROM subscriptions AS prior
    WHERE ${where}
      AND prior.id = s.id
      AND s.redemption_order_id = ${redemptionOrderId}
      AND s.trial_end IS NOT NULL
      AND (s.current_period_end IS NULL OR s.current_period_end <= s.trial_end)
    RETURNING s.user_id, s.status, s.current_period_end, s.next_debit_at, s.updated_at, s.upi_target_app,
              s.merchant_subscription_id, s.price_paise, prior.merchant_subscription_id AS prior_mandate_id
  `) as unknown as (HealedDebit & { updated_at?: Date | string | null; upi_target_app?: string | null })[];
  const row = healed[0];
  if (!row) return null;

  console.warn(
    `[heal] order ${redemptionOrderId} COMPLETED at PhonePe while the row had not recorded it — ` +
      `granted the paid month as '${row.status}' for user ${row.user_id}`,
  );
  await grantReferralReward(sql, row.user_id);
  await reportPostHogFirstConversion(env, {
    userId: row.user_id,
    transactionId: redemptionOrderId,
    amountPaise: Number(row.price_paise),
    occurredAt: row.updated_at ?? null,
    targetApp: row.upi_target_app ?? null,
    merchantSubId: row.merchant_subscription_id,
  });
  return row;
}

/**
 * Take a row out of the autopay rotation WITHOUT touching entitlement: a status outside ('trialing','active') plus
 * `next_debit_at = NULL` removes it from both passes. The cron's park, the status route's revoke/pause heals, the
 * pause webhook and the legacy reconcile all write this ONE statement
 */
export async function parkSubscription(
  env: Env,
  sql: Sql,
  where: Fragment,
  status: "cancelled" | "paused",
  reason: SubscriptionCancelReason = "revoked_at_phonepe",
): Promise<{ user_id: string; prior_status: string | null }[]> {
  const from =
    status === "paused"
      ? sql`s.status IN ('trialing', 'active')`
      : sql`s.status IN ('trialing', 'active', 'paused')`;
  // Self-join so the PRIOR status rides back with the write -> `prior` is the pre-update row under Postgres SET semantics
  const rows = (await sql`
    UPDATE subscriptions AS s
    SET status        = ${status},
        next_debit_at = NULL,
        notified_at   = NULL,
        updated_at    = now()
    FROM subscriptions AS prior
    WHERE ${where}
      AND prior.id = s.id
      AND ${from}
    RETURNING s.user_id, s.merchant_subscription_id, s.price_paise, prior.status AS prior_status, s.updated_at
  `) as unknown as {
    user_id: string;
    merchant_subscription_id: string | null;
    price_paise: number | string | null;
    prior_status: string | null;
    updated_at?: Date | string | null;
  }[];
  if (status === "cancelled" && rows[0]) {
    await reportPostHogSubscriptionCancel(env, {
      userId: rows[0].user_id,
      merchantSubId: rows[0].merchant_subscription_id,
      reason,
      priorStatus: rows[0].prior_status,
      occurredAt: rows[0].updated_at ?? null,
      pricePaise: rows[0].price_paise === null ? null : Number(rows[0].price_paise),
    });
  }
  return rows;
}

/** When the COMPLETED payment moved money (epoch ms), from an order status read with `details=true`. */
export function completedAt(order: {
  paymentDetails?: Array<{ state?: string; timestamp?: number }>;
}): Date | null {
  const ts = order.paymentDetails?.find((p) => p.state === "COMPLETED")?.timestamp;
  return typeof ts === "number" && ts > 0 ? new Date(ts) : null;
}

export function addOneMonth(date: Date): Date {
  const d = new Date(date);
  d.setMonth(d.getMonth() + 1);
  return d;
}
