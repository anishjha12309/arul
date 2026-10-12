/**
 * READ-ONLY: why renewal orders ended the way they did, from the order-outcome log (docs/order-outcomes.md).
 *   cd workers && node tools/payment-failures.mjs            # orders closed in the last 30 days, production
 *   cd workers && node tools/payment-failures.mjs 7          # last 7 days
 *   cd workers && node tools/payment-failures.mjs --debug    # the debug branch
 * SELECTs only. Exit 0 = report printed, 2 = usage/connection error.
 */
import { parseArgs } from "node:util";
import { openBranch } from "./lib/neon-branch.mjs";

const USAGE = "usage: node tools/payment-failures.mjs [days] [--debug]";
let args;
try {
  args = parseArgs({
    options: { debug: { type: "boolean", default: false } },
    allowPositionals: true,
    strict: true,
  });
} catch (err) {
  console.error(`${err.message}\n${USAGE}`);
  process.exit(2);
}
const DAYS = Number(args.positionals[0] ?? 30);
if (!Number.isInteger(DAYS) || DAYS <= 0 || args.positionals.length > 1) {
  console.error(USAGE);
  process.exit(2);
}

const window = `${DAYS} days`;
const sum = (rows) => rows.reduce((a, r) => a + r.n, 0);
const table = (title, rows, label) => {
  console.log(`\n${title}  [total ${sum(rows)}]`);
  if (rows.length === 0) console.log("  (none)");
  for (const r of rows) console.log(`  ${String(r.n).padStart(5)}  ${label(r)}`);
};

const sql = openBranch({ useDebug: args.values.debug });
try {
  console.log(`ORDER OUTCOMES — closed in the last ${DAYS} days`);

  // `closed` is the one read per order made after it could no longer change, so it is the final word
  const bySource = await sql`
    SELECT coalesce(error_source, '-') AS source, phonepe_state AS state, count(*)::int AS n
    FROM order_outcomes
    WHERE event = 'closed' AND observed_at > now() - ${window}::interval
    GROUP BY 1, 2 ORDER BY n DESC
  `;
  table("FINAL STATE, by who PhonePe says caused it", bySource, (r) => `${r.state ?? "-"}  ${r.source}`);

  const byCode = await sql`
    SELECT coalesce(error_source, '-') AS source, coalesce(error_code, '-') AS code,
           coalesce(detailed_error_code, '-') AS detailed, count(*)::int AS n
    FROM order_outcomes
    WHERE event = 'closed' AND phonepe_state <> 'COMPLETED' AND observed_at > now() - ${window}::interval
    GROUP BY 1, 2, 3 ORDER BY n DESC
  `;
  table("NOT PAID, by code", byCode, (r) => `${r.code} / ${r.detailed}  (${r.source})`);

  // A skip is the code PhonePe pins on us: it is ours only if the mandate was live and we never asked to redeem
  // Before the log existed nobody recorded redeem calls -> a backfilled order's "no redeem" means unknown, not none
  const skips = await sql`
    SELECT coalesce(c.mandate_state, '-') AS mandate,
           CASE
             WHEN EXISTS (
               SELECT 1 FROM order_outcomes b
               WHERE b.merchant_order_id = c.merchant_order_id AND b.event = 'minted' AND b.observed_by LIKE 'backfill:%'
             ) THEN 'redeem unknown (backfilled)'
             WHEN EXISTS (
               SELECT 1 FROM order_outcomes r
               WHERE r.merchant_order_id = c.merchant_order_id AND r.event IN ('redeem_accepted', 'redeem_rejected')
             ) THEN 'redeem called'
             ELSE 'NO redeem call'
           END AS redeemed,
           count(*)::int AS n
    FROM order_outcomes c
    WHERE c.event = 'closed' AND c.detailed_error_code = 'SUBSCRIPTION_DEBIT_SKIPPED'
      AND c.observed_at > now() - ${window}::interval
    GROUP BY 1, 2 ORDER BY n DESC
  `;
  table(
    "SKIPPED debits — mandate at the closing read, and whether we called redeem",
    skips,
    (r) => `mandate ${r.mandate}, ${r.redeemed}`,
  );

  const rejected = await sql`
    SELECT coalesce(error_code, '-') AS code, http_status AS http, count(*)::int AS n
    FROM order_outcomes
    WHERE event = 'redeem_rejected' AND observed_at > now() - ${window}::interval
    GROUP BY 1, 2 ORDER BY n DESC
  `;
  table("REDEEM CALLS PHONEPE REFUSED", rejected, (r) => `HTTP ${r.http ?? "-"}  ${r.code}`);

  const [open] = await sql`
    SELECT count(*) FILTER (WHERE coalesce(expire_at, observed_at + interval '72 hours') >= now())::int AS live,
           count(*) FILTER (WHERE coalesce(expire_at, observed_at + interval '72 hours') <  now())::int AS awaiting
    FROM order_outcomes m
    WHERE m.event = 'minted'
      AND NOT EXISTS (SELECT 1 FROM order_outcomes c WHERE c.merchant_order_id = m.merchant_order_id AND c.event = 'closed')
  `;
  console.log("\nNOT YET CLOSED");
  console.log(`  ${String(open.live).padStart(5)}  still inside PhonePe's window`);
  console.log(
    `  ${String(open.awaiting).padStart(5)}  expired, waiting for the hourly closing read (60 an hour)`,
  );
} catch (err) {
  console.error(`payment-failures: ${err.message}`);
  process.exitCode = 2;
} finally {
  await sql.end();
}
