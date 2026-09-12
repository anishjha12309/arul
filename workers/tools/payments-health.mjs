/**
 * "Are payments working right now?" — ONE read-only command, production truth.
 *
 * WHY THIS EXISTS: answering that question used to mean hand-writing six ad-hoc SQL queries and a
 * throwaway PhonePe wrapper, every time, and the one tool that did exist (verify-debits.mjs) was
 * silently reading the DEBUG branch — it cried 209 STUCK while production had zero. Nothing tied the
 * four independent signals together, so "payments are fine" was never a claim anyone could check.
 *
 * The four signals, and why each is here rather than a proxy for another:
 *
 *   GATEWAY   Can we still authenticate at PhonePe, and does it agree with our rows? Only a live
 *             call proves the deployed credentials; Neon looking busy does not. Optional because it
 *             needs credentials that deliberately are NOT on this machine.
 *   CRON      Is the quarter-hour autopay scan running at all? A dead cron looks perfectly healthy
 *             in a revenue chart for a day, which is exactly how 30+ hours of zero conversions once
 *             passed unnoticed (docs/autopay-debits.md).
 *   MONEY     Are debits actually settling, or only being attempted?
 *   BACKLOG   Is anyone stuck mid-debit — paid at PhonePe with nothing to show for it?
 *
 * WHAT IS DELIBERATELY NOT AN ALARM: the day-over-day debit count. That series is pure binomial
 * noise — a chi-square over 27 Aug–7 Sep came out 9.5 on 11 df — so a low day means nothing and a
 * threshold on it would fire constantly and train everyone to ignore this tool. It is PRINTED, with
 * the same-hour comparison that makes a partial day readable, and it never touches the exit code.
 * The alarms are only the two things that are unambiguously wrong: a stuck row, and zero settles
 * across a window in which debits were actually due.
 *
 *   cd workers && node tools/payments-health.mjs
 *   cd workers && node tools/payments-health.mjs --phonepe /path/to/pp.env   # also probe the gateway
 *   cd workers && node tools/payments-health.mjs --debug                     # throwaway branch
 *
 * Exit 0 = healthy, 1 = something needs a human, 2 = usage/connection error.
 * Reads only: SELECTs and PhonePe GETs. No writes, no money moved, safe any time.
 */
import { openBranch } from "./lib/neon-branch.mjs";
import { classify } from "./lib/debit-phases.mjs";
import { loadCreds, getToken, orderStatus, subscriptionStatus } from "./lib/phonepe-read.mjs";

const argv = process.argv.slice(2);
const useDebug = argv.includes("--debug");
const ppIdx = argv.indexOf("--phonepe");
const ppEnvFile = ppIdx >= 0 ? argv[ppIdx + 1] : null;
if (ppIdx >= 0 && !ppEnvFile) {
  console.error("usage: node tools/payments-health.mjs [--phonepe <envfile>] [--debug]");
  process.exit(2);
}

const RUPEE = (paise) => `₹${(Number(paise) / 100).toLocaleString("en-IN")}`;
const pad = (label) => `  ${label} ${".".repeat(Math.max(2, 34 - label.length))} `;

const problems = [];
const notes = [];
let exitCode = 0;

const sql = openBranch({ useDebug });

try {
  console.log(`PAYMENTS HEALTH — ${new Date().toISOString().replace("T", " ").slice(0, 16)}Z\n`);

  // ── Cron liveness ──────────────────────────────────────────────────────────
  // The autopay scan only writes when there is work, so "no write" is not proof of death on its own.
  // The real proof of a dead cron is overdue work sitting un-notified, which the BACKLOG check owns;
  // these timestamps are here to tell a human WHICH failure they are looking at.
  const [beat] = await sql`
    SELECT
      now() AS utc_now,
      max(updated_at)  AS last_write,
      max(notified_at) AS last_notify,
      round(EXTRACT(EPOCH FROM (now() - max(updated_at)))  / 60)::int AS write_min,
      round(EXTRACT(EPOCH FROM (now() - max(notified_at))) / 60)::int AS notify_min
    FROM subscriptions
  `;
  console.log("CRON");
  console.log(pad("last autopay notify") + `${beat.notify_min} min ago`);
  console.log(pad("last subscription write") + `${beat.write_min} min ago`);

  // ── Money ──────────────────────────────────────────────────────────────────
  // first_debit_at is stamped once and never moved by a renewal, so it dates the FIRST ₹199 only.
  // debit_count/paid_paise carry the rest. There is no backfill: the series starts the day the
  // columns landed (db/schema/14_debit_tracking.sql), and an empty day before that is not a fault.
  const [money] = await sql`
    SELECT
      count(*) FILTER (WHERE first_debit_at > now() - interval '24 hours')::int AS debits_24h,
      count(*) FILTER (WHERE first_debit_at > now() - interval  '7 days')::int  AS debits_7d,
      count(*) FILTER (WHERE debit_count > 1)::int                               AS renewed,
      coalesce(sum(paid_paise), 0)                                               AS lifetime_paise
    FROM subscriptions
  `;
  const series = await sql`
    SELECT
      to_char(first_debit_at, 'MM-DD') AS d,
      count(*)::int AS full_day,
      count(*) FILTER (WHERE first_debit_at::time < (now() AT TIME ZONE 'UTC')::time)::int AS to_this_hour
    FROM subscriptions
    -- Whole days only. A rolling "now() - 7 days" cuts the oldest day mid-way and prints a number
    -- far below what that day actually did, which reads as a collapse that never happened.
    WHERE first_debit_at >= date_trunc('day', now()) - interval '6 days'
    GROUP BY 1 ORDER BY 1
  `;
  console.log("\nMONEY");
  console.log(pad("first debits, last 24h") + money.debits_24h);
  console.log(pad("first debits, last 7d") + money.debits_7d);
  console.log(pad("renewals settled") + money.renewed);
  console.log(pad("collected, lifetime") + RUPEE(money.lifetime_paise));
  console.log(`\n  by day (to this hour / full day) — informational, NOT an alarm:`);
  for (const r of series) {
    console.log(`    ${r.d}  ${String(r.to_this_hour).padStart(3)} / ${String(r.full_day).padStart(3)}`);
  }
  console.log(
    "  A low day here is noise, not a signal: the daily series is statistically indistinguishable\n" +
    "  from a coin flip, so judge it over a week and never off one day.",
  );

  // ── Backlog ────────────────────────────────────────────────────────────────
  const { stuck, waiting, inFlight, upcoming } = await classify(sql, 4);
  console.log("\nBACKLOG");
  console.log(pad("due in the next 48h") + upcoming.length);
  console.log(pad("WAITING (inside 24h notify)") + waiting.length);
  console.log(pad("IN FLIGHT (inside 48h settle)") + inFlight.length);
  console.log(pad("STUCK (past the 72h deadline)") + stuck.length);

  if (stuck.length > 0) {
    problems.push(
      `${stuck.length} subscription(s) STUCK past PhonePe's 72h settle deadline. ` +
      `Run: node tools/verify-debits.mjs   (a row there may ALREADY have been debited — read the ` +
      `order state before touching it, and never re-notify a paid order)`,
    );
  }

  // The zero-settle alarm, scoped so it cannot fire on a quiet night: only when debits were actually
  // due in the window. This is the signature of the incident that cost 30+ hours of conversions.
  const [dueRecently] = await sql`
    SELECT count(*)::int AS n
    FROM subscriptions
    WHERE status IN ('trialing', 'active')
      AND next_debit_at BETWEEN now() - interval '24 hours' AND now()
  `;
  if (money.debits_24h === 0 && dueRecently.n > 0) {
    problems.push(
      `ZERO debits settled in 24h while ${dueRecently.n} were due. This is the autopay-starvation ` +
      `signature — check the quarter-hour cron is firing and read docs/autopay-debits.md.`,
    );
  }
  if (money.debits_24h === 0 && dueRecently.n === 0) {
    notes.push("No debits settled in 24h, but none were due either — quiet, not broken.");
  }

  // ── Population ─────────────────────────────────────────────────────────────
  const counts = await sql`
    SELECT status, count(*)::int AS n FROM subscriptions GROUP BY status ORDER BY n DESC
  `;
  console.log("\nPOPULATION");
  console.log("  " + counts.map((r) => `${r.status} ${r.n}`).join(" · "));

  // ── Gateway (optional) ─────────────────────────────────────────────────────
  if (ppEnvFile) {
    console.log("\nGATEWAY");
    const creds = loadCreds({ envFile: ppEnvFile });
    console.log(pad("environment") + creds.env);
    try {
      const token = await getToken(creds);
      console.log(pad("OAuth") + `OK (token len ${token.length})`);

      // Probe the most recently settled row: it is the one case where Neon claims money moved, so
      // PhonePe disagreeing is the finding. An older row proves less and less as time passes.
      const [sample] = await sql`
        SELECT merchant_subscription_id, merchant_order_id
        FROM subscriptions
        WHERE first_debit_at IS NOT NULL AND merchant_order_id IS NOT NULL
        ORDER BY first_debit_at DESC LIMIT 1
      `;
      if (!sample) {
        notes.push("No settled row to cross-check against PhonePe yet.");
      } else {
        const o = await orderStatus(creds, token, sample.merchant_order_id);
        const s = await subscriptionStatus(creds, token, sample.merchant_subscription_id);
        console.log(pad("sample order") + `HTTP ${o.status} ${o.json?.state ?? "?"}`);
        console.log(pad("sample mandate") + `HTTP ${s.status} ${s.json?.state ?? "?"}`);
        console.log(`  (${sample.merchant_subscription_id})`);

        if (o.json?.state !== "COMPLETED") {
          problems.push(
            `Newest settled row ${sample.merchant_subscription_id} reads ` +
            `${o.json?.state ?? `HTTP ${o.status}`} at PhonePe but is marked paid in Neon.`,
          );
        }
        if (s.json?.state && s.json.state !== "ACTIVE") {
          // Drift here is expected at a low rate while no webhook is delivered — REVOKED and PAUSED
          // are the two states only the webhook reports (docs/phonepe-webhook.md). Worth a look, not
          // an outage, so it is a note rather than a failure.
          notes.push(`Newest paid mandate is ${s.json.state} at PhonePe, not ACTIVE — webhook drift.`);
        }
      }
    } catch (err) {
      problems.push(`PhonePe gateway unreachable or credentials rejected: ${err.message}`);
      console.log(pad("OAuth") + "FAILED");
    }
  } else {
    console.log("\nGATEWAY\n  not probed — pass --phonepe <envfile> to cross-check against PhonePe.");
  }

  // ── Verdict ────────────────────────────────────────────────────────────────
  console.log("");
  for (const n of notes) console.log(`NOTE: ${n}`);
  if (problems.length === 0) {
    console.log("VERDICT: HEALTHY — money is moving and nothing is stuck.");
  } else {
    exitCode = 1;
    console.log(`VERDICT: ${problems.length} PROBLEM(S)`);
    for (const p of problems) console.log(`  - ${p}`);
  }
} finally {
  await sql.end();
}

// Exit AFTER the connection is closed, never inside the try. Calling process.exit() while the
// postgres socket is still tearing down trips a libuv assertion on Windows and the process dies with
// 127 — so a genuine failure reported the wrong exit code, which is worse than not reporting at all.
process.exit(exitCode);
