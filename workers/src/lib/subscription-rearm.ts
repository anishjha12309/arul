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
