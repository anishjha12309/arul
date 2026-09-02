/**
 * The version pointer. build-catalog must write catalog/version.json with the current content_version.
 * Its Cache-Control must let the EDGE serve it -> this is the FIRST request of every cold start
 * An uncacheable pointer puts an origin round-trip in front of the whole feed -> that is what this pins
 */

import { describe, it, expect, vi } from "vitest";
import { writeVersionPointer } from "../src/cron/build-catalog.js";

interface PutCall {
  key: string;
  body: Record<string, unknown>;
  opts: { httpMetadata?: { cacheControl?: string; contentType?: string } };
}

function mockR2(): { bucket: R2Bucket; calls: PutCall[] } {
  const calls: PutCall[] = [];
  const bucket = {
    put: vi.fn(async (key: string, value: string, opts: PutCall["opts"]) => {
      calls.push({ key, body: JSON.parse(value), opts });
      return {} as R2Object;
    }),
  } as unknown as R2Bucket;
  return { bucket, calls };
}

describe("writeVersionPointer", () => {
  it("writes catalog/version.json with content_version + an edge-cacheable, client-fresh header", async () => {
    const { bucket, calls } = mockR2();
    await writeVersionPointer(bucket, "42");

    expect(calls).toHaveLength(1);
    expect(calls[0]!.key).toBe("catalog/version.json");
    expect(calls[0]!.body.content_version).toBe("42");
    expect(typeof calls[0]!.body.built_at).toBe("string");

    // Assert the PROPERTIES, never the literal string -> the numbers are tunable, the shape is not
    const cc = calls[0]!.opts.httpMetadata?.cacheControl ?? "";

    // max-age MUST be non-zero -> `max-age=0, s-maxage=30` served DYNAMIC on every request at ~240 ms
    // Cloudflare read max-age=0 as "do not cache" and never applied the s-maxage -> sibling objects cached fine
    // A zero here silently reinstates an origin round-trip in front of every cold start
    const maxAge = /(?:^|[,\s])max-age=(\d+)/.exec(cc);
    expect(maxAge).not.toBeNull();
    expect(Number(maxAge![1])).toBeGreaterThan(0);
    // Staleness after a publish must stay bounded and short -> s-maxage is what bounds it
    expect(Number(maxAge![1])).toBeLessThanOrEqual(60);
    // A burst of cold starts must not stampede origin when it ages out -> stale-while-revalidate is what prevents that
    const swr = /stale-while-revalidate=(\d+)/.exec(cc);
    expect(swr).not.toBeNull();
    expect(Number(swr![1])).toBeGreaterThan(Number(maxAge![1]));
  });
});
