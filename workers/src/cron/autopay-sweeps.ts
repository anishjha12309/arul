/**
 * The top-of-hour passes that heal what no webhook reported: settled debits on rows outside the cron's reach (7b),
 * stranded setup claims (7a), released cancel_99 mandates (4h), revokes the switch grant could not finish, and the
 * legacy merchant's mandate states (it has no webhook). Debits run first; these spend what is left of the run's call
 * budget and wall clock (docs/autopay-debits.md)
 */

import type { Env } from "../env.js";
import { type getDb, toDate } from "../lib/db.js";
import {
  getOrderStatus,
  getSubscriptionStatus,
  mandateCreatedAt,
  PhonePeApiError,
  revokeMandateTolerant,
} from "../lib/phonepe.js";
import { grantReferralReward } from "../lib/referral.js";
import {
  completedAt,
  grantCompletedSetup,
  healSettledDebit,
  honourLateOfferApproval,
  noteRevokeRetry,
  parkSubscription,
  releaseClaim,
  type SetupGrant,
} from "../lib/subscription-state.js";

type Sql = ReturnType<typeof getDb>;

export interface SweepBudget {
  /** Reserve `calls` PhonePe calls before an await; false = the run is out of calls or wall clock. */
  take(calls: number): boolean;
}

const MAX_HEAL_ROWS = 100;

/** The ~11.7k legacy claims stranded since 11 Aug drain at this rate; each is read once and leaves the selection. */
const MAX_PENDING_ROWS = 300;

const MAX_OFFER_ROWS = 50;

const MAX_REVOKE_RETRY_ROWS = 50;

/** ~2.4k legacy trialing/active mandates, 24 top-of-hour ticks a day -> the whole book about daily. */
const MAX_LEGACY_ROWS = 120;

const LANES = 4;

/** An abandoned app never reports back; PhonePe caps a setup intent at 15 min, so a claim this old is decided. */
const CLAIM_STALE_AFTER = "30 minutes";

const CLAIM_GIVE_UP_MS = 2 * 60 * 60 * 1000;

/**
 * A ₹2 approval older than this is revoked, never granted: a trial now would bring a ₹199 notice a day later to
 * someone who approved days ago and never saw premium. The normal path lands within 2 h; this only absorbs an outage
 */
const LATE_GRANT_MS = 24 * 60 * 60 * 1000;

const OFFER_WATCH_MS = 24 * 60 * 60 * 1000;

const REVOKE_ALARM_MS = 72 * 60 * 60 * 1000;

const ENDED_MANDATE_STATES = new Set(["REVOKED", "CANCELLED"]);

const DEAD_MANDATE_STATES = new Set(["REVOKED", "CANCELLED", "EXPIRED", "FAILED"]);

export async function runHourlySweeps(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  await healSettledDebits(env, sql, budget);
  await sweepPendingClaims(env, sql, budget);
  await sweepOfferMandates(env, sql, budget);
  await retryStaleRevokes(env, sql, budget);
  await reconcileLegacyMandates(env, sql, budget);
}

/**
 * 7b: a redemption that settled after its row left ('trialing','active') is money taken with no premium. Fresh
 * claims are skipped: initiate already healed at the tap, and a user may be approving the new setup right now
 */
async function healSettledDebits(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  const rows = (await sql`
    SELECT id, redemption_order_id, status
    FROM subscriptions
    WHERE status IN ('pending', 'cancelled', 'expired', 'paused')
      AND redemption_order_id IS NOT NULL
      AND trial_end IS NOT NULL
      AND (current_period_end IS NULL OR current_period_end <= trial_end)
      AND NOT (status = 'pending' AND updated_at > now() - ${CLAIM_STALE_AFTER}::interval)
    ORDER BY updated_at ASC
    LIMIT ${MAX_HEAL_ROWS}
  `) as unknown as { id: string; redemption_order_id: string; status: string }[];

  const tally = { healed: 0, cleared: 0, open: 0, errors: 0 };
  await inLanes(rows, budget, 3, async (row) => {
    const orderId = row.redemption_order_id;
    // notified_at goes with it, as on the recycle: a row released later with a notice but no order is skipped by
    // Pass A (it selects notified_at IS NULL) and by Pass B (no order to redeem) -> never billed again
    const clearOrder = async () => {
      await sql`
        UPDATE subscriptions SET redemption_order_id = NULL, notified_at = NULL
        WHERE id = ${row.id} AND redemption_order_id = ${orderId}
      `;
      tally.cleared += 1;
    };
    try {
      const order = await getOrderStatus(env, orderId);
      if (order.state === "COMPLETED") {
        const healed = await healSettledDebit(env, sql, sql`s.id = ${row.id}`, orderId);
        if (healed) {
          tally.healed += 1;
          if (healed.prior_mandate_id && healed.prior_mandate_id !== healed.merchant_subscription_id) {
            await revokeLogged(env, healed.prior_mandate_id);
          }
        }
      } else if (order.state === "FAILED" || pastExpiry(order.expireAt)) {
        // Terminal, or open past its own expireAt (it can never settle) -> drop it so the row is not re-read forever
        await clearOrder();
      } else {
        tally.open += 1;
      }
    } catch (err) {
      // An order PhonePe never created cannot settle either -> left in place it would head this pass every hour
      if (isNotFound(err)) {
        await clearOrder();
      } else {
        tally.errors += 1;
        console.warn(`[autopay-sweeps] heal: order ${orderId} status failed:`, err);
      }
    }
  });
  logPass("heal", rows.length, tally);
}

/**
 * 7a: nothing else ever releases a `pending` claim once the app is gone and the legacy merchant sends no webhook ->
 * a parked ₹199 stops billing and an approved first mandate never gets its trial. Read the setup order and decide
 */
async function sweepPendingClaims(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  const rows = (await sql`
    SELECT id, user_id, merchant_subscription_id, merchant_order_id, offer_switch, trial_end, updated_at
    FROM subscriptions
    WHERE status = 'pending'
      AND updated_at < now() - ${CLAIM_STALE_AFTER}::interval
    ORDER BY updated_at ASC
    LIMIT ${MAX_PENDING_ROWS}
  `) as unknown as {
    id: string;
    user_id: string;
    merchant_subscription_id: string | null;
    merchant_order_id: string | null;
    offer_switch: boolean;
    trial_end: unknown;
    updated_at: unknown;
  }[];

  const tally = { granted: 0, switched: 0, released: 0, revoked: 0, open: 0, errors: 0 };
  await inLanes(rows, budget, 4, async (row) => {
    const target = sql`s.id = ${row.id}`;
    const release = async () => {
      if ((await releaseClaim(sql, target)).length > 0) tally.released += 1;
    };
    if (!row.merchant_order_id) {
      await release();
      return;
    }

    let order: Awaited<ReturnType<typeof getOrderStatus>>;
    try {
      order = await getOrderStatus(env, row.merchant_order_id);
    } catch (err) {
      // Never created at PhonePe (the setup call itself failed) -> nothing can complete it
      if (isNotFound(err)) {
        await release();
      } else {
        tally.errors += 1;
        console.warn(`[autopay-sweeps] claim ${row.merchant_order_id} status failed:`, err);
      }
      return;
    }

    const claimedAt = toDate(row.updated_at) ?? new Date(0);
    if (order.state === "COMPLETED") {
      // Only a ₹2 check ages out -> a completed ₹199 TRANSACTION took the money and is always granted
      const pennyDrop = row.offer_switch || row.trial_end === null;
      const doneAt = completedAt(order) ?? claimedAt;
      if (!pennyDrop || Date.now() - doneAt.getTime() <= LATE_GRANT_MS) {
        const granted = await grantCompletedSetup(sql, target, order.paymentFlow?.subscriptionId ?? null);
        if (granted) {
          if (granted.kind === "switch") tally.switched += 1;
          else tally.granted += 1;
          console.log(
            `[autopay-sweeps] claim ${row.merchant_order_id} was approved and never reported — ` +
              `${granted.kind === "switch" ? "switched to ₹99" : `granted as '${granted.status}'`}`,
          );
          await retireStale(env, sql, granted);
          if (granted.kind === "grant" && granted.status === "active") {
            await grantReferralReward(sql, granted.user_id);
          }
        }
        return;
      }
      if (row.merchant_subscription_id && !(await revokeLogged(env, row.merchant_subscription_id))) return;
      tally.revoked += 1;
      console.warn(
        `[autopay-sweeps] claim ${row.merchant_order_id} approved ${Math.round((Date.now() - doneAt.getTime()) / 3_600_000)}h ` +
          `ago and never seen — mandate revoked, claim released (the trial stays theirs)`,
      );
      await release();
      return;
    }

    if (order.state === "FAILED" || order.state === "EXPIRED") {
      await release();
      return;
    }

    if (Date.now() - claimedAt.getTime() > CLAIM_GIVE_UP_MS) {
      if (row.merchant_subscription_id) await revokeLogged(env, row.merchant_subscription_id);
      await release();
      return;
    }
    tally.open += 1;
  });
  logPass("claims", rows.length, tally);
}

/**
 * 4h: a released switch's ₹99 can still be approved in the UPI app. ACTIVE on a row still on its ₹199 is honoured
 * (decision 14); anywhere else it is revoked, never granted
 */
async function sweepOfferMandates(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  const rows = (await sql`
    SELECT id, offer_mandate_id
    FROM subscriptions
    WHERE offer_mandate_id IS NOT NULL
    ORDER BY updated_at ASC
    LIMIT ${MAX_OFFER_ROWS}
  `) as unknown as { id: string; offer_mandate_id: string }[];

  const tally = { honoured: 0, revoked: 0, cleared: 0, open: 0, errors: 0 };
  await inLanes(rows, budget, 4, async (row) => {
    const mandateId = row.offer_mandate_id;
    const clear = async () => {
      await sql`
        UPDATE subscriptions SET offer_mandate_id = NULL
        WHERE id = ${row.id} AND offer_mandate_id = ${mandateId}
      `;
    };
    let state: string;
    let phonepeSubId: string | null = null;
    try {
      const st = await getSubscriptionStatus(env, mandateId);
      state = st.state;
      phonepeSubId = st.subscriptionId ?? null;
    } catch (err) {
      if (isNotFound(err)) {
        await clear();
        tally.cleared += 1;
      } else {
        tally.errors += 1;
        console.warn(`[autopay-sweeps] offer mandate ${mandateId} status failed:`, err);
      }
      return;
    }

    if (state === "ACTIVE") {
      const honoured = await honourLateOfferApproval(sql, mandateId, phonepeSubId);
      if (honoured) {
        tally.honoured += 1;
        console.log(
          `[autopay-sweeps] late ₹99 approval ${mandateId} honoured — user ${honoured.user_id} switched`,
        );
        await retireStale(env, sql, honoured);
        return;
      }
      if (await revokeLogged(env, mandateId)) {
        await clear();
        tally.revoked += 1;
      }
      return;
    }
    if (DEAD_MANDATE_STATES.has(state)) {
      await clear();
      tally.cleared += 1;
      return;
    }
    const createdAt = mandateCreatedAt(mandateId);
    if (createdAt !== null && Date.now() - createdAt.getTime() > OFFER_WATCH_MS) {
      if (await revokeLogged(env, mandateId)) {
        await clear();
        tally.revoked += 1;
      }
      return;
    }
    tally.open += 1;
  });
  logPass("offer mandates", rows.length, tally);
}

/** A parked ₹199 the switch grant could not revoke -> never notified, so it cannot debit; the user still sees it. */
async function retryStaleRevokes(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  const rows = (await sql`
    SELECT id, revoke_retry_mandate_id, revoke_retry_at
    FROM subscriptions
    WHERE revoke_retry_mandate_id IS NOT NULL
    ORDER BY updated_at ASC
    LIMIT ${MAX_REVOKE_RETRY_ROWS}
  `) as unknown as { id: string; revoke_retry_mandate_id: string; revoke_retry_at: unknown }[];

  const tally = { revoked: 0, left: 0 };
  await inLanes(rows, budget, 3, async (row) => {
    const mandateId = row.revoke_retry_mandate_id;
    if (await revokeMandateTolerant(env, mandateId).catch(() => false)) {
      await sql`
        UPDATE subscriptions SET revoke_retry_mandate_id = NULL, revoke_retry_at = NULL
        WHERE id = ${row.id} AND revoke_retry_mandate_id = ${mandateId}
      `;
      tally.revoked += 1;
      return;
    }
    tally.left += 1;
    const since = toDate(row.revoke_retry_at);
    if (since !== null && Date.now() - since.getTime() > REVOKE_ALARM_MS) {
      console.error(
        `[autopay-sweeps] ALARM — replaced ₹199 mandate ${mandateId} still not revoked ` +
          `${Math.round((Date.now() - since.getTime()) / 3_600_000)}h after its first failed revoke; revoke it by hand`,
      );
    }
  });
  logPass("revoke retries", rows.length, tally);
}

/**
 * 7i: a revoke or pause in the UPI app reaches a legacy row only at its next notify or paywall open, so Neon, the CMS
 * and the dashboards count it live meanwhile. Least-recently-checked first; every read moves updated_at, so the
 * rotation reaches the whole legacy book
 */
async function reconcileLegacyMandates(env: Env, sql: Sql, budget: SweepBudget): Promise<void> {
  const rows = (await sql`
    SELECT id, merchant_subscription_id
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND merchant_subscription_id IS NOT NULL
      AND left(merchant_subscription_id, 5) <> 'DKS_H'
    ORDER BY updated_at ASC
    LIMIT ${MAX_LEGACY_ROWS}
  `) as unknown as { id: string; merchant_subscription_id: string }[];

  const tally = { cancelled: 0, paused: 0, live: 0, errors: 0 };
  await inLanes(rows, budget, 1, async (row) => {
    const target = sql`s.id = ${row.id}`;
    try {
      const st = await getSubscriptionStatus(env, row.merchant_subscription_id);
      if (ENDED_MANDATE_STATES.has(st.state)) {
        await parkSubscription(env, sql, target, "cancelled", "revoked_at_phonepe");
        tally.cancelled += 1;
        return;
      }
      if (st.state === "PAUSED") {
        await parkSubscription(env, sql, target, "paused");
        tally.paused += 1;
        return;
      }
      tally.live += 1;
    } catch (err) {
      // A failed read tells us nothing -> never park on it -> but still rotate the cursor
      tally.errors += 1;
      console.warn(`[autopay-sweeps] legacy mandate ${row.merchant_subscription_id} status failed:`, err);
    }
    await sql`
      UPDATE subscriptions SET updated_at = now()
      WHERE id = ${row.id} AND status IN ('trialing', 'active')
    `;
  });
  logPass("legacy mandates", rows.length, tally);
}

/** The switch's replaced ₹199 -> a revoke PhonePe refuses is parked for the hourly retry. */
async function retireStale(env: Env, sql: Sql, grant: SetupGrant): Promise<void> {
  const stale = grant.stale_mandate_id;
  if (!stale) return;
  if (!(await revokeLogged(env, stale)) && grant.kind === "switch") {
    await noteRevokeRetry(sql, grant.user_id, stale);
  }
}

async function revokeLogged(env: Env, mandateId: string): Promise<boolean> {
  try {
    const revoked = await revokeMandateTolerant(env, mandateId);
    if (!revoked) console.error(`[autopay-sweeps] mandate ${mandateId} may STILL BE LIVE at PhonePe`);
    return revoked;
  } catch (err) {
    console.error(`[autopay-sweeps] revoke of ${mandateId} threw:`, err);
    return false;
  }
}

/** PhonePe's answer for an id it never created: SUBSCRIPTION_NOT_FOUND, or ORDER_NOT_FOUND for an order. */
function isNotFound(err: unknown): boolean {
  return (
    err instanceof PhonePeApiError &&
    (err.status === 404 ||
      err.body.includes("SUBSCRIPTION_NOT_FOUND") ||
      err.body.includes("ORDER_NOT_FOUND"))
  );
}

function pastExpiry(expireAt: number | undefined): boolean {
  return typeof expireAt === "number" && expireAt > 0 && Date.now() > expireAt;
}

/**
 * `callsPerRow` is reserved before each row's first await, so no reservation straddles one and the lanes cannot
 * overspend between them. A row that cannot reserve stops the pass; its rows wait for the next hour
 */
async function inLanes<T>(
  rows: T[],
  budget: SweepBudget,
  callsPerRow: number,
  work: (row: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  let stopped = false;
  await Promise.all(
    Array.from({ length: Math.min(LANES, rows.length) }, async () => {
      while (!stopped && next < rows.length) {
        if (!budget.take(callsPerRow)) {
          stopped = true;
          return;
        }
        const row = rows[next++];
        try {
          await work(row);
        } catch (err) {
          console.error("[autopay-sweeps] row failed:", err);
        }
      }
    }),
  );
}

/** ONE line per pass per run -> per-row lines for unchanged rows are how the ones that matter get skimmed past. */
function logPass(name: string, selected: number, tally: Record<string, number>): void {
  const parts = Object.entries(tally)
    .map(([k, v]) => `${v} ${k}`)
    .join(", ");
  console.log(`[autopay-sweeps] ${name} — ${selected} selected (${parts})`);
}
