/**
 * https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
 * FAIL OPEN: an absent binding or a throwing limiter must never block a paying user
 */

/** Client IP for the unauthenticated case -> a missing header degrades to one shared bucket, never to no limit. */
export function clientIp(req: { header: (name: string) => string | undefined }): string {
  return req.header("CF-Connecting-IP") ?? req.header("X-Forwarded-For") ?? "unknown";
}

export async function allowRequest(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    const { success } = await limiter.limit({ key });
    return success;
  } catch (err) {
    console.warn("[ratelimit] limiter threw, allowing request:", err);
    return true;
  }
}

/** 429 envelope -> the app parses every error as { error: { code, message } } -> keep the shape. */
export function tooManyRequests(message = "Too many requests — please slow down"): Response {
  return Response.json(
    { error: { code: "rate_limited", message } },
    { status: 429, headers: { "Retry-After": "60" } },
  );
}
