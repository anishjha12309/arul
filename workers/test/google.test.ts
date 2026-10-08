/**
 * Google idToken verification against a REAL RS256 keypair -> only googleapis and the Cache API are faked.
 * Each test imports a fresh module -> the in-memory key copy is per isolate, and a fresh import is a cold isolate
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { generateKeyPair, exportJWK, SignJWT, errors } from "jose";
import type { JWK } from "jose";

const CLIENT_ID = "test-web-client-id.apps.googleusercontent.com";
const CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs";

type Google = typeof import("../src/lib/google.js");

async function freshModule(): Promise<Google> {
  vi.resetModules();
  return import("../src/lib/google.js");
}

async function makeKey(kid: string) {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk: JWK = { ...(await exportJWK(publicKey)), kid, alg: "RS256", use: "sig" };
  return { kid, jwk, privateKey };
}

type Key = Awaited<ReturnType<typeof makeKey>>;

function sign(key: Key, over: { aud?: string; exp?: string | number } = {}) {
  return new SignJWT({ email: "a@example.com", email_verified: true, name: "A", nonce: "n-1" })
    .setProtectedHeader({ alg: "RS256", kid: key.kid })
    .setIssuer("https://accounts.google.com")
    .setAudience(over.aud ?? CLIENT_ID)
    .setSubject("google-sub-1")
    .setIssuedAt()
    .setExpirationTime(over.exp ?? "1h")
    .sign(key.privateKey);
}

function jwksResponse(keys: Key[], cacheControl = "public, max-age=19000, must-revalidate") {
  return new Response(JSON.stringify({ keys: keys.map((k) => k.jwk) }), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": cacheControl },
  });
}

/** An in-memory stand-in for `caches.default` -> stores the body and headers the Worker put. */
function fakeCache() {
  const store = new Map<string, { body: string; headers: Headers }>();
  const cache = {
    match: vi.fn(async (url: string) => {
      const hit = store.get(url);
      return hit ? new Response(hit.body, { headers: hit.headers }) : undefined;
    }),
    put: vi.fn(async (url: string, res: Response) => {
      store.set(url, { body: await res.text(), headers: new Headers(res.headers) });
    }),
  };
  return { cache, store };
}

/** An in-memory stand-in for the KV binding -> only the two calls google.ts makes. */
function fakeKv() {
  const store = new Map<string, string>();
  const kv = {
    get: vi.fn(async (key: string, type?: string) => {
      const raw = store.get(key);
      if (raw === undefined) return null;
      return type === "json" ? JSON.parse(raw) : raw;
    }),
    put: vi.fn(async (key: string, value: string, _options?: KVNamespacePutOptions) => {
      store.set(key, value);
    }),
  };
  return { kv: kv as unknown as KVNamespace, store, get: kv.get, put: kv.put };
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("verifyGoogleIdToken", () => {
  it("verifies a good token and reuses the in-memory keys for the next one", async () => {
    const key = await makeKey("k1");
    fetchMock.mockImplementation(async () => jwksResponse([key]));
    const g = await freshModule();

    const claims = await g.verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(claims).toEqual({
      sub: "google-sub-1",
      email: "a@example.com",
      email_verified: true,
      name: "A",
      nonce: "n-1",
    });
    await g.verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]![0]).toBe(CERTS_URL);
    // The fetch is bounded -> a hung googleapis socket must not eat the app's login budget
    expect((fetchMock.mock.calls[0]![1] as RequestInit).signal).toBeInstanceOf(AbortSignal);
  });

  it("a cold isolate in the same colo reads the keys from the Cache API, not from Google", async () => {
    const key = await makeKey("k1");
    const { cache } = fakeCache();
    vi.stubGlobal("caches", { default: cache });
    fetchMock.mockImplementation(async () => jwksResponse([key]));

    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(cache.put).toHaveBeenCalledTimes(1);

    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(cache.match).toHaveBeenCalledWith(CERTS_URL);
  });

  it("honours Google's max-age and caps it at 6 h", async () => {
    const key = await makeKey("k1");
    const { cache, store } = fakeCache();
    vi.stubGlobal("caches", { default: cache });

    fetchMock.mockImplementation(async () => jwksResponse([key], "public, max-age=99999, must-revalidate"));
    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(store.get(CERTS_URL)!.headers.get("Cache-Control")).toBe("max-age=21600");

    store.clear();
    fetchMock.mockImplementation(async () => jwksResponse([key], "public, max-age=1200"));
    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(store.get(CERTS_URL)!.headers.get("Cache-Control")).toBe("max-age=1200");
  });

  it("a broken Cache API never fails a login -> it falls through to Google", async () => {
    const key = await makeKey("k1");
    vi.stubGlobal("caches", {
      default: {
        match: vi.fn(async () => {
          throw new Error("cache down");
        }),
        put: vi.fn(async () => {
          throw new Error("cache down");
        }),
      },
    });
    vi.spyOn(console, "warn").mockImplementation(() => {});
    fetchMock.mockImplementation(async () => jwksResponse([key]));

    const claims = await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(claims.sub).toBe("google-sub-1");
  });

  it("a rotated key (unknown kid) refetches ONCE and verifies", async () => {
    const oldKey = await makeKey("old");
    const newKey = await makeKey("new");
    const t0 = Date.now();
    const now = vi.spyOn(Date, "now").mockReturnValue(t0);
    fetchMock.mockImplementationOnce(async () => jwksResponse([oldKey]));
    fetchMock.mockImplementationOnce(async () => jwksResponse([oldKey, newKey]));
    const g = await freshModule();

    await g.verifyGoogleIdToken(await sign(oldKey), CLIENT_ID);
    now.mockReturnValue(t0 + 31_000);
    const claims = await g.verifyGoogleIdToken(await sign(newKey), CLIENT_ID);
    expect(claims.sub).toBe("google-sub-1");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("an unknown kid right after a fetch is a bad token, not a refetch", async () => {
    const key = await makeKey("k1");
    const stranger = await makeKey("junk");
    fetchMock.mockImplementation(async () => jwksResponse([key]));
    const g = await freshModule();

    await g.verifyGoogleIdToken(await sign(key), CLIENT_ID);
    const err = await g.verifyGoogleIdToken(await sign(stranger), CLIENT_ID).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(errors.JWKSNoMatchingKey);
    expect(err).not.toBeInstanceOf(g.GoogleKeysUnavailableError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("wrong audience and expiry stay token errors, never keys-unavailable", async () => {
    const key = await makeKey("k1");
    fetchMock.mockImplementation(async () => jwksResponse([key]));
    const g = await freshModule();

    const wrongAud = await g
      .verifyGoogleIdToken(await sign(key, { aud: "android-client-id" }), CLIENT_ID)
      .catch((e: unknown) => e);
    expect(wrongAud).toBeInstanceOf(errors.JWTClaimValidationFailed);
    expect(wrongAud).not.toBeInstanceOf(g.GoogleKeysUnavailableError);

    const expired = await g
      .verifyGoogleIdToken(await sign(key, { exp: Math.floor(Date.now() / 1000) - 600 }), CLIENT_ID)
      .catch((e: unknown) => e);
    expect(expired).toBeInstanceOf(errors.JWTExpired);
  });

  it("Google answering non-200 is keys-unavailable", async () => {
    const key = await makeKey("k1");
    fetchMock.mockImplementation(async () => new Response("oops", { status: 503 }));
    const g = await freshModule();
    await expect(g.verifyGoogleIdToken(await sign(key), CLIENT_ID)).rejects.toBeInstanceOf(
      g.GoogleKeysUnavailableError,
    );
  });

  it("a network error is keys-unavailable", async () => {
    const key = await makeKey("k1");
    fetchMock.mockImplementation(async () => {
      throw new TypeError("Network connection lost.");
    });
    const g = await freshModule();
    await expect(g.verifyGoogleIdToken(await sign(key), CLIENT_ID)).rejects.toBeInstanceOf(
      g.GoogleKeysUnavailableError,
    );
  });

  it("a hung Google fetch aborts at 3 s as keys-unavailable", async () => {
    const key = await makeKey("k1");
    const token = await sign(key);
    fetchMock.mockImplementation(
      (_url: string, init: RequestInit) =>
        new Promise((_resolve, reject) => {
          init.signal!.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    );
    const g = await freshModule();
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });

    const pending = g.verifyGoogleIdToken(token, CLIENT_ID).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(2_999);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    const err = await pending;
    expect(err).toBeInstanceOf(g.GoogleKeysUnavailableError);
    expect((err as Error).message).toMatch(/timed out/);
  });

  it("an outage after expiry verifies with the expired in-memory copy", async () => {
    const key = await makeKey("k1");
    const t0 = Date.now();
    const now = vi.spyOn(Date, "now").mockReturnValue(t0);
    vi.spyOn(console, "warn").mockImplementation(() => {});
    fetchMock.mockImplementationOnce(async () => jwksResponse([key], "max-age=60"));
    fetchMock.mockImplementationOnce(async () => new Response("down", { status: 500 }));
    const g = await freshModule();

    await g.verifyGoogleIdToken(await sign(key), CLIENT_ID);
    now.mockReturnValue(t0 + 61_000);
    const claims = await g.verifyGoogleIdToken(await sign(key), CLIENT_ID);
    expect(claims.sub).toBe("google-sub-1");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("a colo that never fetched reads the keys another colo wrote to KV, not Google", async () => {
    const key = await makeKey("k1");
    const { kv, put } = fakeKv();
    fetchMock.mockImplementation(async () => jwksResponse([key]));

    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID, kv);
    expect(put).toHaveBeenCalledTimes(1);
    expect(put.mock.calls[0]![2]).toEqual({ expirationTtl: 24 * 60 * 60 });

    // No Cache API stub -> the second isolate is in a colo with nothing cached
    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID, kv);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("a cold colo whose Google fetch fails verifies with an expired KV copy under 24 h old", async () => {
    const key = await makeKey("k1");
    const { kv } = fakeKv();
    const t0 = Date.now();
    const now = vi.spyOn(Date, "now").mockReturnValue(t0);
    vi.spyOn(console, "warn").mockImplementation(() => {});
    fetchMock.mockImplementationOnce(async () => jwksResponse([key], "max-age=60"));
    await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID, kv);

    now.mockReturnValue(t0 + 61_000);
    fetchMock.mockImplementation(async () => {
      throw new TypeError("Network connection lost.");
    });
    const claims = await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID, kv);
    expect(claims.sub).toBe("google-sub-1");
    expect(fetchMock).toHaveBeenCalledTimes(2);

    now.mockReturnValue(t0 + 25 * 60 * 60 * 1000);
    const g = await freshModule();
    await expect(g.verifyGoogleIdToken(await sign(key), CLIENT_ID, kv)).rejects.toBeInstanceOf(
      g.GoogleKeysUnavailableError,
    );
  });

  it("a broken KV never fails a login -> it falls through to Google", async () => {
    const key = await makeKey("k1");
    const kv = {
      get: vi.fn(async () => {
        throw new Error("kv down");
      }),
      put: vi.fn(async () => {
        throw new Error("kv down");
      }),
    } as unknown as KVNamespace;
    vi.spyOn(console, "warn").mockImplementation(() => {});
    fetchMock.mockImplementation(async () => jwksResponse([key]));

    const claims = await (await freshModule()).verifyGoogleIdToken(await sign(key), CLIENT_ID, kv);
    expect(claims.sub).toBe("google-sub-1");
  });
});
