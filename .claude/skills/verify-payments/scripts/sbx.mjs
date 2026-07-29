/**
 * Harness helper — seeds, inspects and drives the isolated test DB.
 *
 * HARD RULE: this connects ONLY to 127.0.0.1:5433 (the embedded Postgres from
 * pgserver.mjs). It refuses to run against any host containing "neon.tech".
 * Seeding a row with a past next_debit_at into production would make the LIVE
 * hourly cron fire real PhonePe calls against it.
 *
 * Commands
 *   seed-user            create the harness user, print its id
 *   token                mint a valid access JWT for that user (uses .dev.vars JWT_SECRET)
 *   subs                 dump every subscription row
 *   due <merchantSubId>  make that subscription due for debit right now
 *                        (status=trialing, next_debit_at in the past, counters reset)
 *   referral             seed a referrer + pending referral for the harness user
 *   rewards              dump referral status + the referrer's reward_premium_until
 *   q "<SQL>"            run arbitrary SQL against the test DB
 */
import postgres from "postgres";
import { SignJWT } from "jose";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../../..");

const vars = Object.fromEntries(
  readFileSync(resolve(repoRoot, "workers/.dev.vars"), "utf8")
    .split(/\r?\n/)
    .filter((l) => l && !l.trimStart().startsWith("#") && l.includes("="))
    .map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
    }),
);

const TEST_URL = "postgresql://postgres:postgres@127.0.0.1:5433/postgres";
if (/neon\.tech/i.test(TEST_URL)) {
  throw new Error("refusing to run against Neon — harness is local-only");
}

const sql = postgres(TEST_URL, { max: 1, fetch_types: false });
const cmd = process.argv[2];
const arg = process.argv[3];

const HARNESS_SUB = "sbx-harness-user";

async function main() {
  switch (cmd) {
    case "seed-user": {
      const [u] = await sql`
        INSERT INTO users (google_sub, email, display_name, referral_code)
        VALUES (${HARNESS_SUB}, 'harness@test.local', 'Harness User', 'SBXTEST1')
        ON CONFLICT (google_sub) DO UPDATE SET email = EXCLUDED.email
        RETURNING id, email
      `;
      console.log(JSON.stringify(u));
      return;
    }

    case "token": {
      const [u] = await sql`SELECT id FROM users WHERE google_sub = ${HARNESS_SUB}`;
      if (!u) throw new Error("run seed-user first");
      // Mirrors signAccessToken: sub + typ, no jti (a jti marks a refresh token).
      const token = await new SignJWT({ sub: u.id, typ: "acc" })
        .setProtectedHeader({ alg: "HS256" })
        .setIssuedAt()
        .setExpirationTime("3600s")
        .sign(new TextEncoder().encode(vars.JWT_SECRET));
      console.log(token);
      return;
    }

    case "subs": {
      console.log(
        JSON.stringify(
          await sql`
            SELECT u.email, s.status, s.merchant_subscription_id, s.phonepe_subscription_id,
                   s.redemption_order_id, s.trial_end, s.current_period_end,
                   s.next_debit_at, s.notified_at, s.retry_count
            FROM subscriptions s JOIN users u ON u.id = s.user_id
            ORDER BY s.updated_at DESC
          `,
          null,
          2,
        ),
      );
      return;
    }

    case "due": {
      if (!arg) throw new Error("usage: due <merchantSubscriptionId>");
      const rows = await sql`
        UPDATE subscriptions
        SET status              = 'trialing',
            next_debit_at       = now() - interval '1 minute',
            current_period_end  = now() - interval '1 minute',
            notified_at         = NULL,
            redemption_order_id = NULL,
            retry_count         = 0
        WHERE merchant_subscription_id = ${arg}
        RETURNING status, next_debit_at, retry_count
      `;
      if (rows.length === 0) throw new Error(`no subscription ${arg}`);
      console.log(JSON.stringify(rows[0]));
      return;
    }

    case "referral": {
      await sql`
        INSERT INTO users (google_sub, email, display_name, referral_code)
        VALUES ('sbx-harness-referrer', 'referrer@test.local', 'Referrer', 'REFCODE1')
        ON CONFLICT (google_sub) DO NOTHING
      `;
      const rows = await sql`
        INSERT INTO referrals (referrer_id, referred_user_id, status)
        SELECT r.id, u.id, 'pending' FROM users r, users u
        WHERE r.google_sub = 'sbx-harness-referrer' AND u.google_sub = ${HARNESS_SUB}
        ON CONFLICT DO NOTHING
        RETURNING id
      `;
      console.log(rows.length ? "referral seeded" : "referral already present");
      return;
    }

    case "rewards": {
      console.log(
        JSON.stringify(
          await sql`
            SELECT rf.status AS referral_status, rf.reward_days, u.reward_premium_until
            FROM referrals rf JOIN users u ON u.id = rf.referrer_id
          `,
          null,
          2,
        ),
      );
      return;
    }

    case "q": {
      if (!arg) throw new Error("usage: q \"<SQL>\"");
      console.log(JSON.stringify(await sql.unsafe(arg), null, 2));
      return;
    }

    default:
      throw new Error(`unknown command: ${cmd ?? "(none)"}`);
  }
}

main()
  .then(() => sql.end())
  .catch(async (e) => {
    console.error("ERR:", e.message);
    await sql.end();
    process.exit(1);
  });
