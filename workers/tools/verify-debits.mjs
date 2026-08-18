/**
 * READ-ONLY billing health check: is any subscriber stuck mid-debit?
 *
 * WHY THIS EXISTS: on 2026-08-16/17 two subscribers were debited ₹199 at PhonePe
 * while their Neon rows stayed `trialing` past their period end — they paid and
 * lost premium for two days, and nothing surfaced it. The cron bug is fixed
 * (docs/autopay-debits.md) but the class of failure is silent by nature: a stuck
 * row looks exactly like a healthy one unless you compare it against the clock.
 *
 * THE INVARIANT: no live subscription may sit past its own `next_debit_at` for
 * longer than the reconcile window. The cron reconciles anything more than 2h
 * overdue on the next hourly tick, so a row still unsettled well past that is
 * either stuck or being retried by PhonePe — both worth a human look.
 *
 *   cd workers && node tools/verify-debits.mjs          # default 4h tolerance
 *   cd workers && node tools/verify-debits.mjs 12       # 12h tolerance
 *
 * Exit 0 = healthy, 1 = something is stuck, 2 = usage/connection error.
 * Reads Neon only — no PhonePe call, no writes, safe to run any time.
 */
import fs from "node:fs";
import postgres from "postgres";

const TOLERANCE_HOURS = Number(process.argv[2] ?? 4);
if (!Number.isFinite(TOLERANCE_HOURS) || TOLERANCE_HOURS <= 0) {
  console.error("usage: node tools/verify-debits.mjs [toleranceHours]");
  process.exit(2);
}

const m = fs
  .readFileSync(new URL("../.dev.vars", import.meta.url), "utf8")
  .match(/postgres(?:ql)?:\/\/[^\s"']+/);
if (!m) {
  console.error("No postgres connection string found in workers/.dev.vars");
  process.exit(2);
}

const sql = postgres(m[0], { ssl: "require", prepare: false, connect_timeout: 10 });

try {
  // Stuck: live status, debit date passed by more than the tolerance, and the
  // period has NOT been extended — i.e. money may have moved with nothing to show.
  const stuck = await sql`
    SELECT
      merchant_subscription_id,
      status,
      redemption_order_id,
      to_char(next_debit_at, 'YYYY-MM-DD HH24:MI') AS due_utc,
      round(EXTRACT(EPOCH FROM (now() - next_debit_at)) / 3600)::int AS overdue_h,
      (current_period_end > now()) AS entitled
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at IS NOT NULL
      AND next_debit_at < now() - ${`${TOLERANCE_HOURS} hours`}::interval
    ORDER BY next_debit_at
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

  const counts = await sql`
    SELECT status, count(*)::int AS n FROM subscriptions GROUP BY status ORDER BY n DESC
  `;

  console.log("Subscription states:");
  for (const r of counts) console.log(`  ${String(r.n).padStart(4)}  ${r.status}`);

  console.log(`\nDebits due in the next 48h: ${upcoming.length}`);
  for (const r of upcoming) {
    console.log(`  ${r.due_utc}Z  ${r.merchant_subscription_id}  ${r.status}` +
      `${r.notified ? "  (notified)" : ""}`);
  }

  if (stuck.length === 0) {
    console.log(`\nOK — nothing overdue by more than ${TOLERANCE_HOURS}h.`);
    process.exit(0);
  }

  console.log(`\nSTUCK — ${stuck.length} subscription(s) overdue by more than ${TOLERANCE_HOURS}h:`);
  for (const r of stuck) {
    console.log(
      `  ${r.merchant_subscription_id}  ${r.status}  due ${r.due_utc}Z  ` +
      `overdue ${r.overdue_h}h  entitled=${r.entitled}  order=${r.redemption_order_id ?? "none"}`,
    );
  }
  console.log(
    `\nA row here may already have been DEBITED at PhonePe. Check the order state before\n` +
    `touching it — see docs/autopay-debits.md. Do NOT re-notify a paid order.`,
  );
  process.exit(1);
} finally {
  await sql.end();
}
