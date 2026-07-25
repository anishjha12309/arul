/**
 * Rate-limit helper over Cloudflare's native rate-limiting binding.
 *
 * Bindings are declared in wrangler.toml under [[ratelimits]] and injected as
 * `env.RL_*`. See https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
 *
 * Two deliberate properties:
 *
 *   1. FAIL OPEN. An absent binding (older deployment, unit tests) or a limiter
 *      that throws must never block a paying user. These limits exist to blunt
 *      abuse of expensive routes, not to enforce correctness — the real
 *      guarantees live in the entitlement check, the one-live-mandate guard and
 *      PhonePe itself. A rate limiter that takes the app down is worse than the
 *      abuse it prevents.
 *
 *   2. KEYED BY ACTOR, NOT IP, wherever an authenticated identity exists.
 *      Cloudflare's own guidance: IP keys punish carrier-grade NAT, which in
 *      India means a single mobile operator's subscribers share a key. User id
 *      is the right unit for /payments and /media. IP is used only where there
 *      is no verified identity yet (login).
 *
 * Counters are per Cloudflare location and eventually consistent, so treat the
 * effective limit as "roughly N per period per colo", not an exact quota.
 */

/** Client IP for the unauthenticated case. Falls back to a constant so a
 *  missing header degrades to one shared bucket rather than to no limit. */
export function clientIp(req: { header: (name: string) => string | undefined }): string {
  return req.header("CF-Connecting-IP") ?? req.header("X-Forwarded-For") ?? "unknown";
}

/**
 * @returns true when the request is allowed to proceed.
 */
export async function allowRequest(
  limiter: RateLimit | undefined,
  key: string,
): Promise<boolean> {
  if (!limiter) return true; // not configured — fail open
  try {
    const { success } = await limiter.limit({ key });
    return success;
  } catch (err) {
    console.warn("[ratelimit] limiter threw, allowing request:", err);
    return true; // fail open
  }
}

/** Standard 429 envelope, matching the app's { error: { code, message } } shape. */
export function tooManyRequests(message = "Too many requests — please slow down"): Response {
  return Response.json(
    { error: { code: "rate_limited", message } },
    { status: 429, headers: { "Retry-After": "60" } },
  );
}
