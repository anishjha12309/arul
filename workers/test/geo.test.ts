/**
 * GET /geo — the region a FRESH install reads once to pick its launch poster.
 *
 * `lang` is always null -> builds that still apply it must open in the phone's language, never a region's
 */

import { describe, it, expect } from "vitest";
import { makeEnv, makeCtx } from "./_ctx.js";
import { handleGeo } from "../src/routes/geo.js";
import worker from "../src/index.js";

type Geo = { country: string | null; region: string | null; lang: string | null };

async function geo(
  cf: Record<string, unknown> | undefined,
  url = "https://arul-api.hsrutility.com/geo?v=2",
): Promise<Geo> {
  const res = handleGeo(makeCtx({ env: makeEnv(), url, ...(cf !== undefined ? { cf } : {}) }));
  expect(res.status).toBe(200);
  return (await res.json()) as Geo;
}

describe("GET /geo — never a language", () => {
  // Every code an older Worker mapped to a language -> now region only
  it.each(["TN", "KA", "KL", "AP", "TS", "TG", "UP", "BR", "MP", "RJ", "HR", "JH", "CG", "UK", "HP", "DL"])(
    "IN + %s -> region reported, lang null",
    async (code) => {
      expect(await geo({ country: "IN", regionCode: code, region: "ignored" })).toEqual({
        country: "IN",
        region: code,
        lang: null,
      });
    },
  );

  // Builds up to 91 call ?v=2 and apply a non-null lang -> every query shape must answer null
  it.each([
    "https://arul-api.hsrutility.com/geo",
    "https://arul-api.hsrutility.com/geo?v=1",
    "https://arul-api.hsrutility.com/geo?v=2",
  ])("%s -> lang null", async (url) => {
    expect((await geo({ country: "IN", regionCode: "TN" }, url)).lang).toBeNull();
  });

  it("upper-cases the country and reports the code as given", async () => {
    expect(await geo({ country: "in", regionCode: "tn" })).toEqual({
      country: "IN",
      region: "tn",
      lang: null,
    });
  });
});

describe("GET /geo — region by NAME when the code is missing", () => {
  it("the raw name is reported", async () => {
    expect(await geo({ country: "IN", regionCode: null, region: "Tamil Nadu" })).toEqual({
      country: "IN",
      region: "Tamil Nadu",
      lang: null,
    });
  });

  // A known code never falls through to the name -> the code is the stronger reading
  it("a code wins over a name", async () => {
    expect((await geo({ country: "IN", regionCode: "DL", region: "Tamil Nadu" })).region).toBe("DL");
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

  it("country missing -> region still reported", async () => {
    expect(await geo({ regionCode: "TN" })).toEqual({ country: null, region: "TN", lang: null });
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
    const res = handleGeo(makeCtx({ env: makeEnv(), cf: { country: "IN", regionCode: "TN" } }));
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("content-type")).toContain("application/json");
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

  it.each(["arul-api.hsrutility.com", "arul-api.twilight-smoke-d495.workers.dev", "arul.hsrutility.com"])(
    "%s -> 200 JSON with the region, never the bounce page",
    async (host) => {
      const res = await worker.fetch(
        request(host, { country: "IN", regionCode: "KL", region: "Kerala" }),
        makeEnv() as never,
        { waitUntil() {}, passThroughOnException() {} } as never,
      );
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("application/json");
      expect(res.headers.get("cache-control")).toBe("no-store");
      const text = await res.text();
      expect(text).not.toContain("location.replace");
      expect(JSON.parse(text)).toEqual({ country: "IN", region: "KL", lang: null });
    },
  );

  it("no cf on the request -> 200 with all three null", async () => {
    const res = await worker.fetch(
      request("arul-api.hsrutility.com"),
      makeEnv() as never,
      { waitUntil() {}, passThroughOnException() {} } as never,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ country: null, region: null, lang: null });
  });
});
