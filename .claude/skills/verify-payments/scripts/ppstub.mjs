/**
 * PhonePe stub — the only way to reach a TERMINAL redemption state locally.
 *
 * PhonePe's UAT sandbox accepts notify and redeem (both verified live), but it
 * holds the redemption PENDING through its own retry cycle and offers no way to
 * settle one on demand. So the branches that actually matter —
 *
 *   COMPLETED → status='active', current_period_end +1 month, referral reward
 *   FAILED    → retry_count++, re-notify next run, expire at MAX_RETRIES
 *
 * — are unreachable against UAT. This stub makes both deterministic.
 *
 * Reads ./mode.txt on EVERY request, so you can switch outcomes mid-run without
 * restarting:  echo FAILED > mode.txt
 *
 * Valid modes: COMPLETED | FAILED | PENDING   (default COMPLETED)
 *
 * Reached only via PHONEPE_BASE_URL_OVERRIDE in workers/.dev.vars, which
 * getPgBase ignores outright when PHONEPE_ENV=PRODUCTION.
 */
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const modeFile = resolve(here, "mode.txt");
const PORT = 8799;

function mode() {
  try {
    const m = readFileSync(modeFile, "utf8").trim().toUpperCase();
    return ["COMPLETED", "FAILED", "PENDING"].includes(m) ? m : "COMPLETED";
  } catch {
    return "COMPLETED";
  }
}

createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const url = req.url ?? "";
    let out;

    if (url.includes("/subscriptions/v2/") && url.includes("/status")) {
      // Pass A refuses to notify unless the mandate is ACTIVE.
      const msid = decodeURIComponent(
        url.split("/subscriptions/v2/")[1].split("/status")[0],
      );
      out = {
        merchantSubscriptionId: msid,
        subscriptionId: "STUB_SUB_1",
        state: "ACTIVE",
        authWorkflowType: "PENNY_DROP",
        amountType: "FIXED",
        maxAmount: "19900",
        frequency: "MONTHLY",
        expireAt: Date.now() + 86_400_000,
      };
    } else if (url.includes("/subscriptions/v2/notify")) {
      out = {
        orderId: "STUB_NOTIFY_ORDER",
        state: "NOTIFICATION_IN_PROGRESS",
        expireAt: Date.now() + 86_400_000,
      };
    } else if (url.includes("/subscriptions/v2/redeem")) {
      const m = mode();
      out = { state: m, transactionId: `STUB_TXN_${m}` };
    } else {
      console.log(`[stub] 404 ${req.method} ${url}`);
      res.writeHead(404, { "Content-Type": "application/json" }).end("{}");
      return;
    }

    console.log(`[stub] ${req.method} ${url.split("?")[0]} -> ${JSON.stringify(out)}`);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(out));
  });
}).listen(PORT, "127.0.0.1", () =>
  console.log(`[stub] listening on 127.0.0.1:${PORT} — mode from ${modeFile}`),
);
