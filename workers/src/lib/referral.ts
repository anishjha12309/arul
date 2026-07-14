/**
 * Referral code generation + reward logic.
 *
 * generateReferralCode — random 8-char code for new users.
 * captureReferral      — on new-user signup, links the referrer + opens a
 *                        'pending' referrals row (best-effort; never blocks login).
 * grantReferralReward  — on a referred user's first paid debit, flips their
 *                        referral to 'rewarded' and credits the referrer with
 *                        REWARD_DAYS of free premium (idempotent, once per pair).
 *
 * Replaces the Supabase RPC resolve_referral_code — now plain parameterized SQL
 * in the Worker (no SECURITY DEFINER needed; Worker holds full DB creds).
 */

import type postgres from "postgres";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no O, 0, I, 1 (ambiguous)

/** Free-premium days granted to the referrer per subscribing friend. */
export const REWARD_DAYS = 30;

/** Generate a random 8-character referral code. */
export function generateReferralCode(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => ALPHABET[b % ALPHABET.length])
    .join("");
}

/** Normalize a user-supplied referral code (share links may vary in case/space). */
export function normalizeReferralCode(raw: string): string {
  return raw.trim().toUpperCase();
}

/**
 * Link a brand-new user to their referrer and open a pending referrals row.
 *
 * Called from /auth/login ONLY for a just-created user, so self-referral is
 * impossible (the new id can't own the code). Best-effort: any failure (unknown
 * code, race, constraint) is swallowed by the caller — a bad code must never
 * break sign-in. Returns the referrer's id when linked, else null.
 *
 * @param sql           postgres.js Sql instance
 * @param newUserId     the just-inserted user's id
 * @param rawCode       the referral code the friend arrived with
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
 * Grant the referral reward for a referred user who just made their first paid
 * debit. Idempotent and safe to call from multiple code paths (payment webhook
 * AND the autopay execute cron both transition a user to 'active'):
 *
 *   1. Flip the user's referral row 'pending'/'subscribed' → 'rewarded'
 *      (reward_days = REWARD_DAYS), guarded by `status <> 'rewarded'` so a
 *      renewal or a retried webhook never double-credits.
 *   2. ONLY if that UPDATE actually changed a row, extend the referrer's
 *      reward_premium_until by REWARD_DAYS (stacking from the later of now / the
 *      existing credit).
 *
 * No-op when the user was not referred, or the reward was already granted.
 *
 * @param sql             postgres.js Sql instance
 * @param referredUserId  the user whose first debit just succeeded
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
