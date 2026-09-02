/**
 * Entitlement check — ALWAYS live from Neon. THE one home of the premium rule (CLAUDE.md §5).
 *
 * Premium = a live paid subscription OR unexpired referral-reward credit -> either alone is enough
 *   A) status IN ('trialing','active','cancelled','pending') AND current_period_end > now()
 *   B) users.reward_premium_until > now()
 * 'cancelled' is in the list -> the current period is already paid for -> keep access to period end
 * 'paused' and 'expired' get NO access and no grace -> access lapses on its own at period end
 * The renewal debit rides the hourly cron -> a flawless payer is past period end for a tick plus UPI settle
 * A strict `> now()` therefore gated EVERY payer at EVERY period boundary -> 6 h DEBIT_GRACE
 * Grace is 'trialing'/'active' ONLY -> a renewal is genuinely in flight, and it absorbs a short bank retry
 * A dunning failure flips the row to 'expired' -> grace ends the same instant -> it cannot be milked
 * The reward pool is granted on a referred friend's FIRST paid debit -> decoupled from the subscription
 * So reward credit stacks with and outlives any PhonePe state -> it never collides with the debit/expiry crons
 * NEVER derive entitlement from the JWT -> `prm` is a UI hint -> every gated action issues this live read
 * Gated actions are a tiny fraction of traffic -> the round-trip is affordable -> do not cache it
 * There is NO test or allow-list bypass -> a declined payment could otherwise grant access -> never add one
 */

import type postgres from "postgres";

/** `userId` is the VERIFIED JWT sub -> a client-supplied id here would be a self-service entitlement. */
export async function isPremium(
  sql: postgres.Sql,
  userId: string,
): Promise<boolean> {
  const rows = await sql`SELECT ${premiumPredicate(sql, userId)} AS ok`;
  return rows[0]?.ok === true;
}

/**
 * The entitlement rule as a composable boolean SQL fragment.
 *
 * A caller already fetching another row (/media/signed-url needs the key) inlines this -> one round-trip, not two
 * Exported as a fragment, never copied -> a drifted second copy hands premium to a lapsed user or locks out a payer
 */
export function premiumPredicate(
  sql: postgres.Sql,
  userId: string,
): postgres.PendingQuery<postgres.Row[]> {
  return sql`
    EXISTS (
      SELECT 1
      FROM users u
      WHERE u.id = ${userId}
        AND (
          (u.reward_premium_until IS NOT NULL AND u.reward_premium_until > now())
          OR EXISTS (
            SELECT 1
            FROM subscriptions s
            WHERE s.user_id = u.id
              AND s.current_period_end IS NOT NULL
              AND (
                -- A resubscribe claims the user's ONE row -> mid-attempt a still-paid row reads as pending
                -- The days already paid for must keep working while the sheet is open -> pending belongs here
                -- A first-time setup has a NULL period -> it gains nothing from this branch
                (s.status IN ('trialing', 'active', 'cancelled', 'pending')
                  AND s.current_period_end > now())
                OR
                -- DEBIT_GRACE: the renewal debit rides the hourly cron -> a payer is past period end each cycle
                -- Never the cancelled status here -> no debit is coming for it -> period end IS the end
                (s.status IN ('trialing', 'active')
                  AND s.current_period_end > now() - interval '6 hours')
              )
          )
        )
    )
  `;
}
