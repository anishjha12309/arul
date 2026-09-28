/**
 * App-sent analytics context stored beside a row for PostHog's warehouse (checkout taps, paywall views).
 * Analytics only -> never read by a payment or entitlement path, and junk is dropped, never an error
 */

export type AnalyticsContext = Record<string, string | number | boolean>;

const KEY_RE = /^[a-z][a-z0-9_]{0,39}$/;
const MAX_KEYS = 60;
const MAX_STRING = 100;

/** Flat scalars only, bounded in keys and length -> null when nothing usable is left. */
export function sanitizeAnalyticsContext(raw: unknown): AnalyticsContext | null {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
  const out: AnalyticsContext = {};
  let kept = 0;
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (kept >= MAX_KEYS || !KEY_RE.test(key)) continue;
    if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) {
      out[key] = value;
    } else if (typeof value === "string") {
      out[key] = value.slice(0, MAX_STRING);
    } else {
      continue;
    }
    kept++;
  }
  return kept > 0 ? out : null;
}
