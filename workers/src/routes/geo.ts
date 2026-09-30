/**
 * Answers from `request.cf` alone -> no DB, no KV, no R2, no rate limiter -> it can never wake Neon or cost a subrequest
 * `cf` is undefined in the preview, local `wrangler dev` and tests -> all three null, still 200 -> only `--remote` has it
 * Never city, coordinates or postal code -> not needed, not stored
 */

import type { Context } from "hono";
import type { Env } from "../env.js";

function known(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

/**
 * The region picks the app's launch poster, never its language
 * `lang` stays in the body, always null -> builds that still read it fall back to the phone
 */
export function handleGeo(c: Context<{ Bindings: Env }>): Response {
  const cf = c.req.raw.cf as Record<string, unknown> | undefined;
  const country = known(cf?.country)?.trim().toUpperCase() ?? null;
  const region = known(cf?.regionCode) ?? known(cf?.region);

  return c.json({ country, region, lang: null }, 200, {
    // One answer per install, and it depends on who is asking -> no shared cache may ever hold it
    "cache-control": "no-store",
  });
}
