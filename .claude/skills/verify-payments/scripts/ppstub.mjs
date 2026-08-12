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

/**
 * mode.txt, two forms:
 *   COMPLETED                       — one word drives redeem AND order status
 *   redeem:PENDING order:COMPLETED  — per-endpoint tokens; unlisted keep defaults
 * Tokens: redeem / order (COMPLETED|FAILED|PENDING), mandate (ACTIVE|CANCELLED|
 * PAUSED…), cancel (OK|FAIL). Split modes exist for Pass C: a debit whose
 * `redeem` stays PENDING while the order's real state is COMPLETED is exactly
 * the webhook-lost case the reconcile exists for — one shared mode can't say it.
 */
function modes() {
  const out = { redeem: "COMPLETED", order: "COMPLETED", mandate: "ACTIVE", cancel: "OK" };
  let raw = "";
  try {
    raw = readFileSync(modeFile, "utf8").trim();
  } catch {
    return out;
  }
  if (!raw) return out;
  if (!raw.includes(":")) {
    const m = raw.toUpperCase();
    if (["COMPLETED", "FAILED", "PENDING"].includes(m)) {
      out.redeem = m;
      out.order = m;
    }
    return out;
  }
  for (const tok of raw.split(/\s+/)) {
    const i = tok.indexOf(":");
    if (i > 0) out[tok.slice(0, i).toLowerCase()] = tok.slice(i + 1).toUpperCase();
  }
  return out;
}
const mode = () => modes().redeem; // back-compat for the redeem branch

createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const url = req.url ?? "";
    let out;

    if (url.includes("/subscriptions/v2/order/") && url.includes("/status")) {
      // Order/redemption status (getOrderStatus) — mode-driven so Pass C's
      // stuck-debit reconcile and the status-guarded abandon are testable.
      // MUST match before the generic mandate-status branch below: an order
      // URL contains both "/subscriptions/v2/" and "/status", so the generic
      // branch would swallow it and answer with a mandate shape.
      const m = modes().order;
      const moid = decodeURIComponent(
        url.split("/subscriptions/v2/order/")[1].split("/status")[0],
      );
      out = {
        orderId: `STUB_PP_${moid}`,
        merchantOrderId: moid,
        state: m,
        amount: 19900,
        paymentFlow: { subscriptionId: "STUB_SUB_1" },
      };
    } else if (url.includes("/subscriptions/v2/") && url.includes("/cancel")) {
      // Merchant cancel — 204 success, or 500 when mode carries cancel:FAIL
      // (the delete-account abort path needs a revoke that verifiably fails
      // while the mandate still reads live).
      if (modes().cancel === "FAIL") {
        console.log(`[stub] ${req.method} ${url.split("?")[0]} -> 500 (cancel:FAIL)`);
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end('{"code":"INTERNAL_SERVER_ERROR"}');
        return;
      }
      console.log(`[stub] ${req.method} ${url.split("?")[0]} -> 204`);
      res.writeHead(204).end();
      return;
    } else if (url.includes("/subscriptions/v2/") && url.includes("/status")) {
      // Pass A refuses to notify unless the mandate is ACTIVE.
      const msid = decodeURIComponent(
        url.split("/subscriptions/v2/")[1].split("/status")[0],
      );
      out = {
        merchantSubscriptionId: msid,
        subscriptionId: "STUB_SUB_1",
        state: modes().mandate,
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
