/**
 * Unit test for the instant-update version pointer. build-catalog must write
 * catalog/version.json with the current content_version and a no-store
 * Cache-Control so the app's always-fresh pointer flips on every publish.
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
  it("writes catalog/version.json with content_version + no-store cache header", async () => {
    const { bucket, calls } = mockR2();
    await writeVersionPointer(bucket, "42");

    expect(calls).toHaveLength(1);
    expect(calls[0]!.key).toBe("catalog/version.json");
    expect(calls[0]!.body.content_version).toBe("42");
    expect(typeof calls[0]!.body.built_at).toBe("string");
    expect(calls[0]!.opts.httpMetadata?.cacheControl).toBe("no-store");
  });
});
