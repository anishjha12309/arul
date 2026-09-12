/**
 * The ONE home for "is this overdue debit actually WRONG, or just slow?".
 *
 * Two tools ask it — `verify-debits.mjs` (per-row detail) and `payments-health.mjs` (counts) — and
 * they must never disagree, because the whole point of the classification is that it separates a
 * real fault from a vendor clock still running. Every boundary below is PhonePe's, not ours.
 *
 * A notified row walks three phases, all derived from `notified_at`:
 *
 *   notify -> +24h ............ WAITING   cannot debit yet (the order's own validAfter)
 *   +24h  -> +72h ............. IN FLIGHT attempted, inside PhonePe's 48h terminal window
 *   +72h onward ............... STUCK     window closed, still not terminal
 *
 * 72h = the 24h notify lead plus the 48h terminal window, and it coincides with the order's own
 * expireAt (notify + 72h observed) — past that PhonePe will never settle it, so it is unambiguously
 * wrong by then. Recycling a dead order restarts the clock, which is how a row can read 50h+ overdue
 * while being perfectly healthy. Reporting THAT as stuck is the false positive that teaches everyone
 * to ignore this check, so the phases are split out and only STUCK affects an exit code.
 *
 * Full derivation and the incidents behind each number: docs/autopay-debits.md.
 */

/** PhonePe: notify must precede the debit by 24h; validAfter = notified_at + 24h. */
export const NOTIFY_LEAD_HOURS = 24;

/**
 * PhonePe: max window for a redemption to reach a terminal status, retries included. Their number,
 * not ours — do not tighten it to match how fast debits usually settle.
 * https://developer.phonepe.com/payment-gateway/autopay/api-integration/api-reference/redemption-execute
 */
export const TERMINAL_WINDOW_HOURS = 48;

/** Past this a notified debit is genuinely wrong, not merely slow. */
export const SETTLE_DEADLINE_HOURS = NOTIFY_LEAD_HOURS + TERMINAL_WINDOW_HOURS;

/**
 * Classifies every live subscription overdue by more than `toleranceHours`.
 *
 * `toleranceHours` governs ONE case only: a row overdue that was never notified at all. That is our
 * cron failing to run, not PhonePe being slow, so it has no vendor clock to wait on and 4h is right
 * for it. Notified rows are judged purely on the phase boundaries above.
 */
export async function classify(sql, toleranceHours) {
  const overdue = `${toleranceHours} hours`;
  const settle = `${SETTLE_DEADLINE_HOURS} hours`;
  const lead = `${NOTIFY_LEAD_HOURS} hours`;

  // Stuck: live status, debit date passed by more than the tolerance, and the period has NOT been
  // extended — i.e. money may have moved with nothing to show for it.
  const stuck = await sql`
    SELECT
      merchant_subscription_id,
      status,
      redemption_order_id,
      to_char(next_debit_at, 'YYYY-MM-DD HH24:MI') AS due_utc,
      round(EXTRACT(EPOCH FROM (now() - next_debit_at)) / 3600)::int AS overdue_h,
      (current_period_end > now()) AS period_live
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at IS NOT NULL
      AND next_debit_at < now() - ${overdue}::interval
      -- A notified row is only wrong once PhonePe's own settle clock has run out. Before that it is
      -- WAITING (cannot debit) or IN FLIGHT (may still settle) — neither is evidence of a fault.
      AND (notified_at IS NULL OR notified_at <= now() - ${settle}::interval)
    ORDER BY next_debit_at
  `;

  // Overdue, but the order physically cannot debit yet: healthy by rule.
  const waiting = await sql`
    SELECT
      merchant_subscription_id,
      status,
      round(EXTRACT(EPOCH FROM (now() - next_debit_at)) / 3600)::int AS overdue_h,
      to_char(notified_at + ${lead}::interval, 'YYYY-MM-DD HH24:MI') AS debits_after,
      to_char(notified_at + ${settle}::interval, 'YYYY-MM-DD HH24:MI') AS order_expires
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at IS NOT NULL
      AND next_debit_at < now() - ${overdue}::interval
      AND notified_at IS NOT NULL
      AND notified_at > now() - ${lead}::interval
    ORDER BY notified_at
  `;

  // Attempted, and PhonePe still has time on the clock. Not a fault yet.
  const inFlight = await sql`
    SELECT
      merchant_subscription_id,
      status,
      round(EXTRACT(EPOCH FROM (now() - next_debit_at)) / 3600)::int AS overdue_h,
      to_char(notified_at + ${settle}::interval, 'YYYY-MM-DD HH24:MI') AS terminal_by
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at IS NOT NULL
      AND next_debit_at < now() - ${overdue}::interval
      AND notified_at IS NOT NULL
      AND notified_at <= now() - ${lead}::interval
      AND notified_at > now() - ${settle}::interval
    ORDER BY notified_at
  `;

  const upcoming = await sql`
    SELECT
      merchant_subscription_id,
      status,
      to_char(next_debit_at, 'YYYY-MM-DD HH24:MI') AS due_utc,
      (notified_at IS NOT NULL) AS notified
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at BETWEEN now() AND now() + interval '48 hours'
    ORDER BY next_debit_at
  `;

  return { stuck, waiting, inFlight, upcoming };
}
