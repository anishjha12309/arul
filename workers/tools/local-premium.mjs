/**
 * Debug-branch premium switch for local testing of gated actions (docs/local-stack.md). Never production.
 *
 *   node tools/local-premium.mjs grant <email> [--days 30]   # users.reward_premium_until = now() + N days
 *   node tools/local-premium.mjs revoke <email>              # reward_premium_until = NULL
 *   node tools/local-premium.mjs status <email>
 *
 * Revoke clears the comp only: a live subscription row on the debug branch still grants premium
 * (lib/entitlement.ts premiumPredicate), and the output shows that row so the result is never a surprise.
 */
import { parseArgs } from "node:util";
import { openDebugForWrite, refuse, refuseRemoteFlags } from "./local-lib.mjs";

refuseRemoteFlags(process.argv.slice(2));
const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: { days: { type: "string", default: "30" } },
});
const [action, email] = positionals;
if (!["grant", "revoke", "status"].includes(action) || !email) {
  console.error("usage: node tools/local-premium.mjs <grant|revoke|status> <email> [--days N]");
  process.exit(2);
}
const days = Number(values.days);
if (!Number.isInteger(days) || days < 1 || days > 3650) refuse("--days must be an integer 1..3650");

const sql = openDebugForWrite();
try {
  const users = await sql`SELECT id FROM users WHERE lower(email) = lower(${email})`;
  if (users.length === 0)
    refuse(`no user with email ${email} on the debug branch — sign in once on the local stack`);
  if (users.length > 1) refuse(`${users.length} users share ${email} on the debug branch — fix by hand`);
  const id = users[0].id;

  if (action === "grant") {
    await sql`UPDATE users SET reward_premium_until = now() + make_interval(days => ${days}) WHERE id = ${id}`;
  } else if (action === "revoke") {
    await sql`UPDATE users SET reward_premium_until = NULL WHERE id = ${id}`;
  }
  const [row] = await sql`
    SELECT u.reward_premium_until, s.status, s.current_period_end
    FROM users u LEFT JOIN subscriptions s ON s.user_id = u.id
    WHERE u.id = ${id}
  `;
  console.log(
    `[premium] ${action} ${email}: reward_premium_until=${row.reward_premium_until?.toISOString() ?? "null"} · ` +
      `subscription=${row.status ?? "none"}${row.current_period_end ? ` until ${row.current_period_end.toISOString()}` : ""}`,
  );
  if (action === "revoke" && row.status && row.current_period_end > new Date()) {
    console.log("[premium] note: that subscription row can still grant premium on its own");
  }
  console.log("[premium] gated actions read this live; reopen the app (or pull to refresh) for the UI badge");
} finally {
  await sql.end();
}
