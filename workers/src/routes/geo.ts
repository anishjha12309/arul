/**
 * Answers from `request.cf` alone -> no DB, no KV, no R2, no rate limiter -> it can never wake Neon or cost a subrequest
 * `cf` is undefined in the preview, local `wrangler dev` and tests -> all three null, still 200 -> only `--remote` has it
 * Never city, coordinates or postal code -> not needed, not stored
 */

import type { Context } from "hono";
import type { Env } from "../env.js";

/**
 * Telangana has carried both TS and TG -> accept both
 */
const LANG_BY_CODE: Readonly<Record<string, string>> = {
  TN: "ta",
  KA: "kn",
  KL: "ml",
  AP: "te",
  TS: "te",
  TG: "te",
  UP: "hi",
  BR: "hi",
  MP: "hi",
  RJ: "hi",
  HR: "hi",
  JH: "hi",
  CG: "hi",
  UK: "hi",
  HP: "hi",
};

/** The same map by ISO 3166-2 NAME, lower-cased -> used only when Cloudflare knows the name but not the code. */
const LANG_BY_NAME: Readonly<Record<string, string>> = {
  "tamil nadu": "ta",
  karnataka: "kn",
  kerala: "ml",
  "andhra pradesh": "te",
  telangana: "te",
  "uttar pradesh": "hi",
  bihar: "hi",
  "madhya pradesh": "hi",
  rajasthan: "hi",
  haryana: "hi",
  jharkhand: "hi",
  chhattisgarh: "hi",
  uttarakhand: "hi",
  "himachal pradesh": "hi",
};

function known(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function handleGeo(c: Context<{ Bindings: Env }>): Response {
  const cf = c.req.raw.cf as Record<string, unknown> | undefined;
  const country = known(cf?.country)?.trim().toUpperCase() ?? null;
  const code = known(cf?.regionCode);
  const name = known(cf?.region);

  // A known code never falls back to the name -> the code is the stronger reading
  const versioned = c.req.query("v") === "2";
  let lang: string | null = null;
  if (c.env.GEO_LANG_ENABLED === "true" && versioned && country === "IN") {
    lang = code
      ? (LANG_BY_CODE[code.trim().toUpperCase()] ?? null)
      : name
        ? (LANG_BY_NAME[name.trim().toLowerCase()] ?? null)
        : null;
  }

  return c.json({ country, region: code ?? name, lang }, 200, {
    // One answer per install, and it depends on who is asking -> no shared cache may ever hold it
    "cache-control": "no-store",
  });
}
