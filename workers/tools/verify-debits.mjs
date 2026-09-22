/**
 * READ-ONLY billing health check: is any subscriber stuck mid-debit?
 *
 * WHY THIS EXISTS: on 2026-08-16/17 two subscribers were debited ₹199 at PhonePe while their Neon
 * rows stayed `trialing` past their period end — they paid and lost premium for two days, and
 * nothing surfaced it. The cron bug is fixed (docs/autopay-debits.md) but the class of failure is
 * silent by nature: a stuck row looks exactly like a healthy one unless you compare it against the
 * clock.
 *
 * THE INVARIANT: no live subscription may sit past its own `next_debit_at` for longer than PhonePe's
 * own settle window. What counts as "longer", why a row can read 50h+ overdue while being perfectly
 * healthy, and where every boundary comes from now live in tools/lib/debit-phases.mjs — one home,
 * shared with payments-health.mjs so the two can never disagree.
 *
 * This tool answers the BACKLOG half alone. For the wider "are payments working at all" question —
 * gateway reachable, credentials valid, money actually landing, cron alive — run
 * `node tools/payments-health.mjs`.
 *
 *   cd workers && node tools/verify-debits.mjs            # 4h un-notified tolerance, production
 *   cd workers && node tools/verify-debits.mjs 12         # 12h
 *   cd workers && node tools/verify-debits.mjs --debug    # the throwaway branch instead
 *
 * Exit 0 = healthy, 1 = something is stuck, 2 = usage/connection error.
 * Reads Neon only — no PhonePe call, no writes, safe to run any time.
 */
import { openBranch } from "./lib/neon-branch.mjs";
import { classify, SETTLE_DEADLINE_HOURS, TERMINAL_WINDOW_HOURS } from "./lib/debit-phases.mjs";

const argv = process.argv.slice(2);
// `--debug` reads the throwaway branch instead of production — the same flag prod-query.mjs takes.
const useDebug = argv.includes("--debug");
const TOLERANCE_HOURS = Number(argv.filter((a) => a !== "--debug")[0] ?? 4);
if (!Number.isFinite(TOLERANCE_HOURS) || TOLERANCE_HOURS <= 0) {
  console.error("usage: node tools/verify-debits.mjs [toleranceHours] [--debug]");
  process.exit(2);
}

let exitCode = 0;

// Selected BY NAME and announced — see tools/lib/neon-branch.mjs for the outage this hid.
const sql = openBranch({ useDebug });

try {
  const { stuck, waiting, inFlight, upcoming } = await classify(sql, TOLERANCE_HOURS);

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

  if (waiting.length > 0) {
    console.log(
      `
WAITING — ${waiting.length} overdue but inside PhonePe's 24h notify ` +
      `window, so not yet chargeable (NOT stuck):`,
    );
    for (const r of waiting) {
      console.log(
        `  ${r.merchant_subscription_id}  ${r.status}  overdue ${r.overdue_h}h  ` +
        `debits after ${r.debits_after}Z  order expires ${r.order_expires}Z`,
      );
    }
  }

  if (inFlight.length > 0) {
    console.log(
      `
IN FLIGHT — ${inFlight.length} debit(s) attempted and still inside ` +
      `PhonePe's ${TERMINAL_WINDOW_HOURS}h settle window (NOT stuck):`,
    );
    for (const r of inFlight) {
      console.log(
        `  ${r.merchant_subscription_id}  ${r.status}  overdue ${r.overdue_h}h  ` +
        `must be terminal by ${r.terminal_by}Z`,
      );
    }
  }

  if (stuck.length === 0) {
    console.log(`\nOK — no debit past its ${SETTLE_DEADLINE_HOURS}h settle deadline, none un-notified beyond ${TOLERANCE_HOURS}h.`);
  } else {
    exitCode = 1;
    console.log(`\nSTUCK — ${stuck.length} subscription(s) past PhonePe's ${SETTLE_DEADLINE_HOURS}h settle deadline, or overdue and never notified:`);
    for (const r of stuck) {
      console.log(
        `  ${r.merchant_subscription_id}  ${r.status}  due ${r.due_utc}Z  ` +
        `overdue ${r.overdue_h}h  period_live=${r.period_live}  order=${r.redemption_order_id ?? "none"}`,
      );
    }
    console.log(
      `\nA row here may already have been DEBITED at PhonePe. Check the order state before\n` +
      `touching it — see docs/autopay-debits.md. Do NOT re-notify a paid order.`,
    );
  }
} finally {
  await sql.end();
}

// Exit AFTER the connection is closed — process.exit() mid-teardown trips a libuv assertion on
// Windows and reports 127 instead of the real code. See payments-health.mjs for the same note.
process.exit(exitCode);
