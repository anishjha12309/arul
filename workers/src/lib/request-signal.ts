/**
 * Cloudflare's view of the caller's connection, merged into the analytics the Worker already returns or
 * stores (login analytics, paywall views, checkout rows) -> the carrier and link quality ride for free.
 * Never city or coordinates: PostHog's own GeoIP covers city, and the Worker stores neither.
 */

import type { AnalyticsContext } from "./analytics-context.js";

/** Empty off the edge (`wrangler dev`, tests), where `request.cf` does not exist. */
export function requestSignal(req: Request | undefined): AnalyticsContext {
  const cf = (req as (Request & { cf?: Record<string, unknown> }) | undefined)?.cf;
  if (!cf) return {};
  const out: AnalyticsContext = {};
  const text = (key: string, value: unknown) => {
    if (typeof value === "string" && value.trim()) out[key] = value.trim().slice(0, 60);
  };
  const num = (key: string, value: unknown) => {
    if (typeof value === "number" && Number.isFinite(value)) out[key] = value;
  };
  text("isp", cf.asOrganization);
  num("rtt_ms", cf.clientTcpRtt ?? cf.clientQuicRtt);
  text("colo", cf.colo);
  text("region_code", cf.regionCode);
  num("asn", cf.asn);
  text("http", cf.httpProtocol);
  text("tls", cf.tlsVersion);
  return out;
}
