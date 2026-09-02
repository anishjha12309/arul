/**
 * Referral code generation + reward logic. Plain parameterized SQL — the Worker holds full DB creds.
 *
 * The reward is credited once per PAIR, on the referred friend's first PAID debit -> never on signup
 */

import type postgres from "postgres";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no O, 0, I, 1 (ambiguous)

/** Free-premium days granted to the referrer per subscribing friend. */
export const REWARD_DAYS = 30;

export function generateReferralCode(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => ALPHABET[b % ALPHABET.length])
    .join("");
}

/** A code arrives typed or pasted from a share link -> case and spacing vary -> normalize before every lookup. */
export function normalizeReferralCode(raw: string): string {
  return raw.trim().toUpperCase();
}

/**
 * Link a brand-new user to their referrer and open a pending referrals row.
 *
 * Called ONLY for a just-created user -> the new id cannot own any code yet -> self-referral is impossible
 * Best-effort: the caller swallows every failure -> an unknown code, a race or a constraint must not break sign-in
 */
export async function captureReferral(
  sql: postgres.Sql,
  newUserId: string,
  rawCode: string,
): Promise<string | null> {
  const code = normalizeReferralCode(rawCode);
  if (!code) return null;

  const referrers = await sql<{ id: string }[]>`
    SELECT id FROM users
    WHERE referral_code = ${code}
      AND id <> ${newUserId}
    LIMIT 1
  `;
  if (referrers.length === 0) return null;
  const referrerId = referrers[0].id;

  await sql`
    UPDATE users SET referred_by = ${referrerId} WHERE id = ${newUserId}
  `;
  await sql`
    INSERT INTO referrals (referrer_id, referred_user_id, status)
    VALUES (${referrerId}, ${newUserId}, 'pending')
    ON CONFLICT (referred_user_id) DO NOTHING
  `;
  return referrerId;
}

/**
 * Grant the referral reward for a user whose first paid debit just succeeded.
 *
 * Both the payment webhook and the autopay execute cron flip a user to 'active' -> this runs twice -> idempotent
 * The `status <> 'rewarded'` guard is what makes it so -> a renewal or a retried webhook never double-credits
 * The credit is applied ONLY when that UPDATE changed a row -> RETURNING is the idempotency test, not a convenience
 * Credit stacks from the LATER of now and the existing expiry -> a second reward extends, it does not restart
 */
export async function grantReferralReward(
  sql: postgres.Sql,
  referredUserId: string,
): Promise<void> {
  const rewarded = await sql<{ referrer_id: string }[]>`
    UPDATE referrals
    SET status = 'rewarded', reward_days = ${REWARD_DAYS}
    WHERE referred_user_id = ${referredUserId}
      AND status <> 'rewarded'
    RETURNING referrer_id
  `;
  if (rewarded.length === 0) return; // not referred, or already rewarded

  const referrerId = rewarded[0].referrer_id;
  await sql`
    UPDATE users
    SET reward_premium_until =
          GREATEST(COALESCE(reward_premium_until, now()), now())
          + (${REWARD_DAYS} || ' days')::interval
    WHERE id = ${referrerId}
  `;
}
