/**
 * Unit test for the version pointer. build-catalog must write
 * catalog/version.json with the current content_version and a Cache-Control that
 * lets the EDGE serve it while keeping clients from holding their own copy —
 * this file is the first request of every cold start, so an uncacheable pointer
 * put an origin round-trip in front of the whole feed.
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

    // Assert the properties, not the literal string — the numbers are tunable,
    // the shape is not.
    const cc = calls[0]!.opts.httpMetadata?.cacheControl ?? "";

    // max-age MUST be non-zero. `max-age=0, s-maxage=30` was measured serving
    // cf-cache-status: DYNAMIC on 12/12 requests at ~240 ms while every sibling
    // object cached fine — Cloudflare read max-age=0 as "do not cache" and never
    // applied the s-maxage. A zero here silently reinstates an origin round-trip
    // in front of every cold start.
    const maxAge = /(?:^|[,\s])max-age=(\d+)/.exec(cc);
    expect(maxAge).not.toBeNull();
    expect(Number(maxAge![1])).toBeGreaterThan(0);
    // Staleness after a publish stays bounded and short.
    expect(Number(maxAge![1])).toBeLessThanOrEqual(60);
    // And a burst of cold starts must not stampede origin when it ages out.
    const swr = /stale-while-revalidate=(\d+)/.exec(cc);
    expect(swr).not.toBeNull();
    expect(Number(swr![1])).toBeGreaterThan(Number(maxAge![1]));
  });
});
