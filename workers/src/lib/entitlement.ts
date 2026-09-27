/**
 * Gated actions are a tiny fraction of traffic -> the round-trip is affordable -> do not cache it
 */

import type postgres from "postgres";

/** `userId` is the VERIFIED JWT sub -> a client-supplied id here would be a self-service entitlement. */
export async function isPremium(sql: postgres.Sql, userId: string): Promise<boolean> {
  const rows = await sql`SELECT ${premiumPredicate(sql, userId)} AS ok`;
  return rows[0]?.ok === true;
}

/**
 * A caller already fetching another row (/media/signed-url needs the key) inlines this -> one round-trip, not two
 * Exported as a fragment, never copied -> a drifted second copy hands premium to a lapsed user or locks out a payer
 * `userId` takes a BOUND VALUE (one caller, one user) or a SQL FRAGMENT naming a column, which is
 * what makes the rule usable per row. The push audience query needs "every device whose owner is
 * paying" and passes `sql`d.user_id`` -> the EXISTS becomes correlated against the outer row instead
 * of a second copy of the rule living in the audience builder.
 */
export function premiumPredicate(
  sql: postgres.Sql,
  userId: string | postgres.PendingQuery<postgres.Row[]>,
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
