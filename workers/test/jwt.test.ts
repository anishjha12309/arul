/**
 * Unit tests for JWT sign/verify/rotation logic.
 * No network calls — all crypto is synchronous via Web Crypto API (mocked by vitest).
 */

import { describe, it, expect, vi } from "vitest";
import {
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
  verifyRefreshToken,
  denylistJti,
  isJtiDenylisted,
} from "../src/lib/jwt.js";

const TEST_SECRET = "test-secret-must-be-at-least-32-bytes-long!";

describe("JWT — access token", () => {
  it("signs and verifies a valid access token", async () => {
    const token = await signAccessToken("user-uuid-123", TEST_SECRET);
    expect(typeof token).toBe("string");
    expect(token.split(".").length).toBe(3); // JWS compact

    const claims = await verifyAccessToken(token, TEST_SECRET);
    expect(claims.sub).toBe("user-uuid-123");
  });

  it("includes prm hint when provided", async () => {
    const token = await signAccessToken("user-uuid-123", TEST_SECRET, true);
    const claims = await verifyAccessToken(token, TEST_SECRET);
    expect(claims.prm).toBe(true);
  });

  it("omits prm when not provided", async () => {
    const token = await signAccessToken("user-uuid-123", TEST_SECRET);
    const claims = await verifyAccessToken(token, TEST_SECRET);
    expect(claims.prm).toBeUndefined();
  });

  it("rejects a token signed with a different secret", async () => {
    const token = await signAccessToken("user-uuid-123", TEST_SECRET);
    await expect(
      verifyAccessToken(token, "wrong-secret-must-be-at-least-32-bytes!!"),
    ).rejects.toThrow();
  });

  it("rejects a malformed token", async () => {
    await expect(verifyAccessToken("not.a.token", TEST_SECRET)).rejects.toThrow();
  });
});

describe("JWT — refresh token", () => {
  it("issues a refresh token with a unique jti", async () => {
    const { token, jti } = await signRefreshToken("user-uuid-123", TEST_SECRET);
    expect(typeof jti).toBe("string");
    expect(jti.length).toBeGreaterThan(0);

    const claims = await verifyRefreshToken(token, TEST_SECRET);
    expect(claims.sub).toBe("user-uuid-123");
    expect(claims.jti).toBe(jti);
  });

  it("issues unique jtis on each call", async () => {
    const { jti: jti1 } = await signRefreshToken("user-uuid-123", TEST_SECRET);
    const { jti: jti2 } = await signRefreshToken("user-uuid-123", TEST_SECRET);
    expect(jti1).not.toBe(jti2);
  });
});

describe("JWT — KV denylist", () => {
  // Mock KVNamespace
  function makeMockKV(): KVNamespace {
    const store = new Map<string, string>();
    return {
      put: vi.fn(async (key: string, value: string, opts?: { expirationTtl?: number }) => {
        void opts;
        store.set(key, value);
      }),
      get: vi.fn(async (key: string) => store.get(key) ?? null),
      delete: vi.fn(async (key: string) => { store.delete(key); }),
      list: vi.fn(async () => ({ keys: [], list_complete: true, cursor: undefined })),
      getWithMetadata: vi.fn(async () => ({ value: null, metadata: null })),
    } as unknown as KVNamespace;
  }

  it("denylist stores jti and isJtiDenylisted returns true", async () => {
    const kv = makeMockKV();
    const jti = "test-jti-abc";
    const futureExp = Math.floor(Date.now() / 1000) + 3600;

    await denylistJti(kv, jti, futureExp);
    const denylisted = await isJtiDenylisted(kv, jti);
    expect(denylisted).toBe(true);
  });

  it("isJtiDenylisted returns false for unknown jti", async () => {
    const kv = makeMockKV();
    const denylisted = await isJtiDenylisted(kv, "unknown-jti");
    expect(denylisted).toBe(false);
  });

  it("denylistJti sets TTL based on remaining lifetime", async () => {
    const kv = makeMockKV();
    const putSpy = vi.spyOn(kv, "put");
    const futureExp = Math.floor(Date.now() / 1000) + 7200; // 2h from now

    await denylistJti(kv, "my-jti", futureExp);

    expect(putSpy).toHaveBeenCalledOnce();
    const callArgs = putSpy.mock.calls[0];
    expect(callArgs[0]).toBe("jti:my-jti");
    expect(callArgs[1]).toBe("1");
    const opts = callArgs[2] as { expirationTtl: number };
    // Should be ~7200s (with a small margin for test execution time)
    expect(opts.expirationTtl).toBeGreaterThan(7000);
    expect(opts.expirationTtl).toBeLessThanOrEqual(7200);
  });
});
