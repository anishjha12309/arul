/**
 * End-to-end check that ONE trial converted to a paid subscription. Reads production; writes only the report.
 *   cd workers && node tools/verify-conversion.mjs --sub DKS_S_...
 *   cd workers && node tools/verify-conversion.mjs --sub DKS_S_... --order <OrderId> [--report-dir <dir>]
 *   cd workers && node tools/verify-conversion.mjs --sub DKS_S_... --dry-run   # print the commands, run nothing
 *
 * Two subscribers were once debited at PhonePe while Neon still said `trialing`, and nothing surfaced it. The
 * cron bug is fixed (docs/autopay-debits.md), but a conversion still has to be WATCHED: a silent failure looks
 * exactly like success. Three independent layers, because any one of them can lie:
 *   1. Neon — did the row actually become a paying subscriber?   (prod-query.mjs)
 *   2. Neon — is anything else stuck mid-debit?                  (verify-debits.mjs)
 *   3. KV   — did the GA4 purchase event reach Google? The receipt key is written only after GA4 returns OK,
 *             so it cannot be faked by intent.
 * Writes <report-dir>/arul-billing-check_<yyyy-MM-dd_HHmm>.txt (default ~/Desktop) and opens it with `open`.
 * No -SelfDestruct: it only deleted the Windows scheduled task that launched the check, so it was dropped.
 * Needs workers/.dev.vars and a wrangler login, which is why it cannot be a cloud routine.
 * Exit 0 = PASS, 1 = PARTIAL or FAIL, 2 = usage.
 */
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const WORKERS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const KV_NAMESPACE_ID = "8bf33c34e2ec41cd8ca98611dc5a70fb";
const RULE = "=".repeat(70);

let opt;
try {
  ({ values: opt } = parseArgs({
    strict: true,
    options: {
      sub: { type: "string" },
      order: { type: "string", default: "" },
      "report-dir": { type: "string", default: path.join(os.homedir(), "Desktop") },
      "dry-run": { type: "boolean", default: false },
    },
  }));
} catch (err) {
  usage(err.message);
}
const sub = opt.sub ?? "";
// The id is spliced into the SQL below -> only the characters a merchant subscription id uses.
if (!/^[A-Za-z0-9_-]+$/.test(sub)) usage("--sub <MerchantSubId> is required (letters, digits, _ and - only)");
const orderId = opt.order;

const now = new Date();
const p2 = (n) => String(n).padStart(2, "0");
const day = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-${p2(now.getDate())}`;
const hh = p2(now.getHours());
const mm = p2(now.getMinutes());
const report = path.join(path.resolve(opt["report-dir"]), `arul-billing-check_${day}_${hh}${mm}.txt`);

const query =
  "SELECT merchant_subscription_id, status, current_period_end > now() AS entitled, " +
  "to_char(current_period_end,'YYYY-MM-DD HH24:MI') AS period_end, redemption_order_id " +
  `FROM subscriptions WHERE merchant_subscription_id = '${sub}'`;
const STEPS = {
  subscription: [process.execPath, ["tools/prod-query.mjs", query]],
  debits: [process.execPath, ["tools/verify-debits.mjs"]],
  kv: [
    "npx",
    [
      "wrangler",
      "kv",
      "key",
      "list",
      "--namespace-id",
      KV_NAMESPACE_ID,
      "--remote",
      "--prefix",
      "ga4:purchase:",
    ],
  ],
};

if (opt["dry-run"]) dryRun();
else verify();

/** Prints every command a real run would spawn, in order, and spawns nothing. */
function dryRun() {
  console.log(`[dry-run] cwd ${WORKERS_DIR}`);
  for (const [cmd, args] of Object.values(STEPS))
    console.log(`[dry-run] ${[cmd, ...args].map(sh).join(" ")}`);
  console.log(`[dry-run] would write ${report}`);
  console.log(`[dry-run] ${["open", report].map(sh).join(" ")}`);
}

function verify() {
  const lines = [];
  const add = (t) => {
    lines.push(t);
    console.log(t);
  };

  add(`Arul billing verification - ${day} ${hh}:${mm} IST`);
  add(`Subscription: ${sub}`);
  add(RULE);

  add("\n[1] Subscription state (Neon)");
  const subscription = run(STEPS.subscription);
  add(subscription.out);
  const converted =
    /"status":\s*"active"/i.test(subscription.out) && /"entitled":\s*true/i.test(subscription.out);

  add("\n[2] Fleet-wide stuck-debit check");
  const health = run(STEPS.debits);
  add(health.out);

  // The KV key is written ONLY after GA4 accepts the Measurement Protocol call -> a receipt, not an intention.
  add("\n[3] GA4 purchase receipts (KV)");
  const kv = run(STEPS.kv);
  add(kv.out);

  let purchaseReported = false;
  if (orderId !== "") {
    purchaseReported = kv.out.toLowerCase().includes(orderId.toLowerCase());
    add(`\nLooking for order ${orderId} -> ${purchaseReported ? "FOUND" : "NOT FOUND"}`);
  }

  add(`\n${RULE}`);
  const pass = converted && health.ok && (orderId === "" || purchaseReported);
  if (pass) {
    add("PASS - trial converted to paid, nothing stuck, purchase reported to GA4.");
  } else if (converted) {
    add("PARTIAL - the subscription IS active and paid, but another check failed. Read above.");
  } else {
    add(
      `FAIL - ${sub} did not convert. Do NOT re-notify or re-run redemptions: ` +
        "the money may already have been taken. Read docs/autopay-debits.md and check the " +
        "PhonePe order state first.",
    );
  }
  process.exitCode = pass ? 0 : 1;

  try {
    fs.writeFileSync(report, lines.join("\n") + "\n");
    console.log(`\nReport written to: ${report}`);
    // Pop it so the result is seen rather than sitting in a file nobody opens.
    spawnSync("open", [report], { stdio: "ignore" });
  } catch (err) {
    console.error(`\nCould not write the report to ${report}: ${err.message}`);
  }
}

/** Runs one step from workers/ and returns stdout + stderr together, trimmed, like `2>&1`. */
function run([cmd, args]) {
  const r = spawnSync(cmd, args, { cwd: WORKERS_DIR, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}${r.error ? `${r.error.message}\n` : ""}`;
  return { out: out.trim(), ok: r.status === 0 };
}

/** Quotes one argument for display so a dry-run line can be pasted into zsh or bash as-is. */
function sh(arg) {
  return /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, `'\\''`)}'`;
}

function usage(msg) {
  console.error(msg);
  console.error(
    "usage: node tools/verify-conversion.mjs --sub <MerchantSubId> [--order <OrderId>] [--report-dir <dir>] [--dry-run]",
  );
  process.exit(2);
}
