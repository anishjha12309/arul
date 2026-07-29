/**
 * Entitlement check — ALWAYS reads live from Neon.
 *
 * Rule (from CLAUDE.md §5 and architecture.md §0). A user is premium if EITHER:
 *   A) they hold a live paid subscription:
 *        status IN ('trialing', 'active', 'cancelled')
 *        AND current_period_end IS NOT NULL AND current_period_end > now()
 *   B) they hold unexpired referral-reward credit:
 *        users.reward_premium_until IS NOT NULL AND reward_premium_until > now()
 *
 * 'cancelled' is included on purpose: when a user cancels (or revokes the
 * mandate from their PSP app), the CURRENT period is already paid for, so they
 * keep premium until current_period_end — only the auto-renewal stops. Access
 * then lapses naturally when the period ends. 'paused' and 'expired' get NO
 * access.
 *
 * The reward pool (B) is granted by grantReferralReward() when a referred friend
 * makes their first paid debit. It is intentionally decoupled from the
 * subscription lifecycle so it stacks with — and outlives — any PhonePe state
 * and never collides with the debit/expiry crons.
 *
 * This is NEVER trusted from the JWT token (the token carries only `sub`).
 * Every gated action calls this function, which issues a live DB read.
 * The cost is negligible because gated actions are a tiny fraction of traffic.
 *
 * There is NO test/allow-list bypass: premium is determined SOLELY by live rows
 * in Neon, so a declined/failed payment can never grant access. (The former
 * PREMIUM_TEST_USER_IDS hook was removed 2026-07-01.)
 *
 * The query uses parameterized SQL (no string interpolation) and is scoped
 * to the verified `userId` from the JWT.
 */

import type postgres from "postgres";

/**
 * Check whether a user currently has premium access (paid subscription OR
 * unexpired referral-reward credit).
 * @param sql    postgres.js Sql instance from getDb(env)
 * @param userId The user's UUID (from verified JWT sub claim)
 */
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
 * Callers that already need another row in the same request — /media/signed-url
 * needs the content key — can inline this instead of issuing a second query,
 * turning two sequential Hyperdrive round-trips into one. Exported as a fragment
 * rather than copied so there is exactly ONE place the premium rule lives: a
 * second hand-written copy that drifted would either hand premium media to a
 * lapsed user or lock out a paying one.
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
              AND s.status IN ('trialing', 'active', 'cancelled')
              AND s.current_period_end IS NOT NULL
              AND s.current_period_end > now()
          )
        )
    )
  `;
}
