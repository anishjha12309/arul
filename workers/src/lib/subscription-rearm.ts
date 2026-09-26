/**
 * The ONE unpause restore — a paused row going back into the billing rotation, status AND clock.
 *
 * Three callers write it: the `subscription.unpaused` webhook, the `/payments/status` lost-unpause
 * heal (both routes/payments.ts) and the cron's Pass D recheck (cron/autopay-notify.ts).
 * It lives here because they must never drift:
 * REARMING IS NOT OPTIONAL. The cron's park NULLs `next_debit_at`, so a status-only restore leaves a
 * row neither Pass A nor Pass B can ever select again — the app says "Active" forever, nothing is
 * billed, and premium dies silently at period end. COALESCE keeps a webhook-paused row's original
 * schedule; `notified_at = NULL` sends it through Pass A for a fresh pre-debit notice first.
 *
 * The `AND status = 'paused'` guard is load-bearing in BOTH directions: a stray unpause must never
 * resurrect a cancelled or expired row, whose `next_debit_at` is gone ON PURPOSE.
 */

import type { getDb } from "./db.js";

export interface RearmedSubscription {
  status: string;
  next_debit_at: unknown;
}

/**
 * Restore + rearm a paused subscription. Empty result = nothing matched, i.e. the row was not paused.
 *
 * ONE statement for both scopes, never two near-identical ones: an unmatched key is bound NULL, and
 * `col = NULL` is NULL, so the OR can only ever be satisfied by the key the caller actually passed.
 * The webhook knows the mandate id; the cron knows the row id.
 */
export async function rearmUnpausedSubscription(
  sql: ReturnType<typeof getDb>,
  target: { subscriptionId?: string | null; merchantSubscriptionId?: string | null },
): Promise<RearmedSubscription[]> {
  const subscriptionId = target.subscriptionId ?? null;
  const merchantSubscriptionId = target.merchantSubscriptionId ?? null;
  return (await sql`
    UPDATE subscriptions
    SET status        = CASE
                          WHEN trial_end IS NOT NULL AND trial_end > now()
                          THEN 'trialing' ELSE 'active'
                        END,
        next_debit_at = COALESCE(next_debit_at, current_period_end),
        notified_at   = NULL,
        updated_at    = now()
    WHERE (id = ${subscriptionId} OR merchant_subscription_id = ${merchantSubscriptionId})
      AND status = 'paused'
    RETURNING status, next_debit_at
  `) as unknown as RearmedSubscription[];
}
