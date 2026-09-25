/**
 * GET /geo — the region hint a FRESH install reads once to open in its state's language.
 *
 * A wrong answer fails SILENTLY -> a Tennessee user opens in Tamil, a Delhi user in Hindi, and nothing logs
 * The map is the owner's decision, state by state -> every mapped code and every deliberate miss is pinned here
 */

import { describe, it, expect } from "vitest";
import { makeEnv, makeCtx } from "./_ctx.js";
import { handleGeo } from "../src/routes/geo.js";
import worker from "../src/index.js";

type Geo = { country: string | null; region: string | null; lang: string | null };

const ON = { GEO_LANG_ENABLED: "true" };

async function geo(
  cf: Record<string, unknown> | undefined,
  env = makeEnv(ON),
  url = "https://arul-api.hsrutility.com/geo?v=2",
): Promise<Geo> {
  const res = handleGeo(makeCtx({ env, url, ...(cf !== undefined ? { cf } : {}) }));
  expect(res.status).toBe(200);
  return (await res.json()) as Geo;
}

describe("GET /geo — India, by region code", () => {
  // The five southern codes, and TG beside TS -> Telangana has carried both as its ISO code
  it.each([
    ["TN", "ta"],
    ["KA", "kn"],
    ["KL", "ml"],
    ["AP", "te"],
    ["TS", "te"],
    ["TG", "te"],
  ])("IN + %s -> %s", async (code, lang) => {
    expect(await geo({ country: "IN", regionCode: code, region: "ignored" })).toEqual({
      country: "IN",
      region: code,
      lang,
    });
  });

  it.each(["UP", "BR", "MP", "RJ", "HR", "JH", "CG", "UK", "HP"])("IN + %s -> hi", async (code) => {
    expect(await geo({ country: "IN", regionCode: code })).toEqual({
      country: "IN",
      region: code,
      lang: "hi",
    });
  });

  // Delhi is unmapped ON PURPOSE -> its South-Indian migrants who switch outnumber its Hindi pickers
  it.each(["DL", "MH", "GJ", "WB", "PB"])("IN + %s -> no hint, region still reported", async (code) => {
    expect(await geo({ country: "IN", regionCode: code })).toEqual({
      country: "IN",
      region: code,
      lang: null,
    });
  });

  it("upper-cases the country and matches the code case-blind", async () => {
    expect(await geo({ country: "in", regionCode: "tn" })).toEqual({
      country: "IN",
      region: "tn",
      lang: "ta",
    });
  });
});

describe("GET /geo — India, by region NAME when the code is missing", () => {
  it.each([
    ["Tamil Nadu", "ta"],
    ["Uttar Pradesh", "hi"],
    ["  tamil NADU ", "ta"],
  ])("IN + %j -> %s, the raw name reported", async (name, lang) => {
    expect(await geo({ country: "IN", regionCode: null, region: name })).toEqual({
      country: "IN",
      region: name,
      lang,
    });
  });

  it("an unmapped name -> no hint", async () => {
    expect(await geo({ country: "IN", region: "National Capital Territory of Delhi" })).toEqual({
      country: "IN",
      region: "National Capital Territory of Delhi",
      lang: null,
    });
  });

  // A known code never falls through to the name -> the code is the stronger reading
  it("an unmapped code does not fall back to a mapped name", async () => {
    expect((await geo({ country: "IN", regionCode: "DL", region: "Tamil Nadu" })).lang).toBeNull();
  });
});

describe("GET /geo — outside India", () => {
  // regionCode is scoped to its country -> US+TN is Tennessee -> the country gate comes first
  it("US + TN is Tennessee, never Tamil", async () => {
    expect(await geo({ country: "US", regionCode: "TN", region: "Tennessee" })).toEqual({
      country: "US",
      region: "TN",
      lang: null,
    });
  });

  it.each(["XX", "T1"])("country %s (unknown / Tor) -> no hint", async (country) => {
    expect((await geo({ country, regionCode: "TN" })).lang).toBeNull();
  });

  it("country missing -> no hint", async () => {
    expect(await geo({ regionCode: "TN" })).toEqual({ country: null, region: "TN", lang: null });
  });
});

describe("GET /geo — degraded inputs", () => {
  // The preview, local `wrangler dev` and unit tests hand the Worker no cf object at all
  it("cf undefined -> all three null, still 200", async () => {
    expect(await geo(undefined)).toEqual({ country: null, region: null, lang: null });
  });

  it("empty strings read as unknown", async () => {
    expect(await geo({ country: "", regionCode: "", region: "" })).toEqual({
      country: null,
      region: null,
      lang: null,
    });
  });

  // Never city, coordinates or postal code -> not needed, not stored
  it("answers exactly three keys", async () => {
    const body = await geo({
      country: "IN",
      regionCode: "TN",
      region: "Tamil Nadu",
      city: "Chennai",
      latitude: "13.08",
      longitude: "80.27",
      postalCode: "600001",
    });
    expect(Object.keys(body).sort()).toEqual(["country", "lang", "region"]);
  });

  it("is never cached", () => {
    const res = handleGeo(makeCtx({ env: makeEnv(ON), cf: { country: "IN", regionCode: "TN" } }));
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("content-type")).toContain("application/json");
  });
});

// Builds before the factorial call a bare /geo -> they must keep the phone's language or the test's cohort is polluted
describe("GET /geo — only v=2 callers get a language", () => {
  it.each([
    "https://arul-api.hsrutility.com/geo",
    "https://arul-api.hsrutility.com/geo?v=1",
    "https://arul-api.hsrutility.com/geo?v=",
  ])("%s -> lang null, region intact", async (url) => {
    expect(await geo({ country: "IN", regionCode: "TN" }, makeEnv(ON), url)).toEqual({
      country: "IN",
      region: "TN",
      lang: null,
    });
  });
});

describe("GEO_LANG_ENABLED kill switch", () => {
  // Off must keep country + region -> measurement continues while the default is dark
  it.each([undefined, "false", "TRUE", "1", " true", ""])("%j -> lang null, region intact", async (value) => {
    const env = makeEnv(value === undefined ? {} : { GEO_LANG_ENABLED: value });
    expect(await geo({ country: "IN", regionCode: "TN" }, env)).toEqual({
      country: "IN",
      region: "TN",
      lang: null,
    });
  });
});

// The handler tests above bypass Hono's router -> a path with no ROUTE 404s in production while they stay green
describe("real router: /geo", () => {
  function request(host: string, cf?: Record<string, unknown>): Request {
    const req = new Request(`https://${host}/geo?v=2`);
    // A Node Request carries no cf -> attach the one the edge would have -> Hono hands it over as c.req.raw
    if (cf) Object.defineProperty(req, "cf", { value: cf });
    return req;
  }

  it.each([
    "arul-api.hsrutility.com",
    "arul-api.twilight-smoke-d495.workers.dev",
    "arul.hsrutility.com",
  ])("%s -> 200 JSON with the mapped language, never the bounce page", async (host) => {
    const res = await worker.fetch(
      request(host, { country: "IN", regionCode: "KL", region: "Kerala" }),
      makeEnv(ON) as never,
      { waitUntil() {}, passThroughOnException() {} } as never,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(res.headers.get("cache-control")).toBe("no-store");
    const text = await res.text();
    expect(text).not.toContain("location.replace");
    expect(JSON.parse(text)).toEqual({ country: "IN", region: "KL", lang: "ml" });
  });

  it("no cf on the request -> 200 with all three null", async () => {
    const res = await worker.fetch(
      request("arul-api.hsrutility.com"),
      makeEnv(ON) as never,
      { waitUntil() {}, passThroughOnException() {} } as never,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ country: null, region: null, lang: null });
  });
});
