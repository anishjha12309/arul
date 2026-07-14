/**
 * PhonePe webhook dispatcher — POST /payments/webhook (OUTSIDE /admin, no
 * session auth: PhonePe authenticates with its own callback Authorization
 * header, verified by the RECEIVING app Worker, not here).
 *
 * WHY: PhonePe sends ALL of the merchant's S2S callbacks (both apps) to
 * api.hsrutility.com/payments/webhook. This Worker owns that route and relays
 * each event to the right app Worker via service binding:
 *
 *   merchant id starts with "DKS_"  →  ARUL_API   (Arul's phonepe.ts generates
 *                                       DKS_S_… / DKS_O_… / DKS_R_… ids)
 *   anything else (incl. parse failures, missing id) → PAKIZA_API
 *                                       (Pakiza is the incumbent registrant)
 *
 * Extraction mirrors the app Workers' webhook handlers
 * (workers/src/routes/payments.ts): body is JSON with a `payload` object;
 * the MERCHANT-generated ids are payload.merchantOrderId and
 * payload.merchantSubscriptionId (payload.orderId is PhonePe's own id and is
 * never DKS_-prefixed, so it is NOT used for routing).
 *
 * The request is forwarded VERBATIM — same method, same path, all original
 * headers (especially Authorization), the exact raw body bytes — and the
 * downstream response is returned as-is so PhonePe sees the target Worker's
 * response. The two app Workers may verify DIFFERENT webhook credentials;
 * that's provisioned via each Worker's own secrets, not handled here.
 */

import type { Context } from "hono";
import type { Env } from "./env.js";

type Ctx = Context<{ Bindings: Env }>;

/**
 * Pull the merchant-generated id out of a PhonePe webhook body, mirroring
 * workers/src/routes/payments.ts (`payload.payload.merchantOrderId` /
 * `payload.payload.merchantSubscriptionId`). Returns null when the body is
 * not JSON or carries no merchant id — the caller falls back to Pakiza.
 */
export function extractMerchantId(rawBody: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const pp = (parsed as { payload?: unknown }).payload;
  if (typeof pp !== "object" || pp === null) return null;
  const inner = pp as { merchantOrderId?: unknown; merchantSubscriptionId?: unknown };
  if (typeof inner.merchantOrderId === "string" && inner.merchantOrderId) {
    return inner.merchantOrderId;
  }
  if (typeof inner.merchantSubscriptionId === "string" && inner.merchantSubscriptionId) {
    return inner.merchantSubscriptionId;
  }
  return null;
}

export async function handlePaymentsWebhook(c: Ctx): Promise<Response> {
  // Read the exact raw bytes ONCE; decode a copy for the routing peek so the
  // forwarded body is byte-identical to what PhonePe signed.
  const rawBytes = await c.req.raw.arrayBuffer();
  const rawText = new TextDecoder().decode(rawBytes);

  const merchantId = extractMerchantId(rawText);
  const isArul = merchantId !== null && merchantId.startsWith("DKS_");
  if (!isArul) {
    console.warn(
      `[payments/dispatch] Routing to PAKIZA_API (fallback): merchantId=${merchantId ?? "<none/unparseable>"}`,
    );
  }
  const target = isArul ? c.env.ARUL_API : c.env.PAKIZA_API;
  const targetName = isArul ? "ARUL_API" : "PAKIZA_API";

  if (!target) {
    console.error(`[payments/dispatch] Service binding ${targetName} not configured`);
    return Response.json(
      { error: { code: "dispatch_unavailable", message: `${targetName} binding missing` } },
      { status: 502 },
    );
  }

  try {
    // Same method, same path (/payments/webhook via the original URL), all
    // original headers (incl. Authorization), exact raw body bytes.
    const forwarded = new Request(c.req.raw.url, {
      method: c.req.raw.method,
      headers: c.req.raw.headers,
      body: rawBytes,
    });
    // Return the downstream response AS-IS — PhonePe sees the app Worker's
    // status/body, so its retry semantics stay driven by the real handler.
    return await target.fetch(forwarded);
  } catch (err) {
    console.error(`[payments/dispatch] Forward to ${targetName} failed:`, err);
    return Response.json(
      { error: { code: "dispatch_failed", message: `Forward to ${targetName} failed` } },
      { status: 502 },
    );
  }
}
