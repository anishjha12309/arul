/**
 * Rate-limit helper over Cloudflare's native binding — [[ratelimits]] in wrangler.toml, injected as `env.RL_*`.
 * https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
 *
 * FAIL OPEN: an absent binding or a throwing limiter must never block a paying user
 * These blunt abuse of expensive routes, they enforce nothing -> correctness lives in the entitlement
 * check, the one-live-mandate guard and PhonePe -> a limiter that takes the app down is the worse failure
 * KEYED BY ACTOR, NOT IP, wherever an identity is verified -> carrier-grade NAT shares one IP across a
 * whole Indian operator's subscribers -> user id for /payments and /media, IP only pre-login
 * Counters are per colo and eventually consistent -> read the limit as "roughly N per period per colo", not a quota
 */

/** Client IP for the unauthenticated case -> a missing header degrades to one shared bucket, never to no limit. */
export function clientIp(req: { header: (name: string) => string | undefined }): string {
  return req.header("CF-Connecting-IP") ?? req.header("X-Forwarded-For") ?? "unknown";
}

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

/** 429 envelope -> the app parses every error as { error: { code, message } } -> keep the shape. */
export function tooManyRequests(message = "Too many requests — please slow down"): Response {
  return Response.json(
    { error: { code: "rate_limited", message } },
    { status: 429, headers: { "Retry-After": "60" } },
  );
}
