/**
 * Shared route-handler test helpers — an in-memory KV, a tagged-template SQL mock, a fake Env, a Hono Context.
 *
 * The SQL mock returns the SAME rows for every query -> a test needing per-query answers must sequence its own
 * Handlers reach the DB through getDb(env) -> each test file mocks ../src/lib/db.js to return env._testSql
 * Not a *.test.ts file -> vitest never runs it directly
 */

import { vi } from "vitest";
import type { Context } from "hono";
import type { Env } from "../src/env.js";

export function makeMockKV(initial?: Map<string, string>): KVNamespace {
  const store = initial ?? new Map<string, string>();
  return {
    put: vi.fn(async (key: string, value: string) => {
      store.set(key, value);
    }),
    get: vi.fn(async (key: string, type?: string) => {
      const raw = store.get(key) ?? null;
      if (raw === null) return null;
      if (type === "json") {
        try {
          return JSON.parse(raw) as unknown;
        } catch {
          return null;
        }
      }
      return raw;
    }),
    delete: vi.fn(async (key: string) => {
      store.delete(key);
    }),
    list: vi.fn(async () => ({ keys: [], list_complete: true, cursor: undefined })),
    getWithMetadata: vi.fn(async () => ({ value: null, metadata: null })),
  } as unknown as KVNamespace;
}

export interface MockSqlHandle {
  sql: unknown;
  capturedArgs: unknown[][];
}

/** Tagged-template SQL mock: every invocation records its args and resolves [rows]. */
export function makeMockSql(rows: unknown[]): MockSqlHandle {
  const capturedArgs: unknown[][] = [];
  const fn = vi.fn((...args: unknown[]) => {
    capturedArgs.push(args);
    return Promise.resolve(rows);
  });
  const sql = Object.assign(fn, { end: vi.fn().mockResolvedValue(undefined) });
  return { sql, capturedArgs };
}

export function makeEnv(overrides: Record<string, unknown> = {}): Env {
  return {
    KV: makeMockKV(),
    HYPERDRIVE: {} as Hyperdrive,
    // Minimal R2 stub -> head() resolves truthy so an upload "exists", and delete() is a no-op
    // Override head per-test to simulate a missing object -> `head: async () => null`
    R2: {
      head: vi.fn(async () => ({ key: "stub" })),
      delete: vi.fn(async () => {}),
    } as unknown as R2Bucket,
    JWT_SECRET: "test-jwt-secret-must-be-at-least-32-bytes!!",
    GOOGLE_WEB_CLIENT_ID: "test-google-client-id",
    R2_ACCESS_KEY_ID: "test-r2-key",
    R2_SECRET_ACCESS_KEY: "test-r2-secret",
    R2_ENDPOINT: "https://acct.r2.cloudflarestorage.com",
    R2_BUCKET: "south-indian-wallpapers",
    R2_CDN_BASE_URL: "https://cdn.hsrutility.com",
    PHONEPE_MERCHANT_ID: "M",
    PHONEPE_CLIENT_ID: "cid",
    PHONEPE_CLIENT_SECRET: "csec",
    PHONEPE_CLIENT_VERSION: "1",
    PHONEPE_WEBHOOK_USERNAME: "u",
    PHONEPE_WEBHOOK_PASSWORD: "p",
    PHONEPE_ENV: "SANDBOX",
    CATALOG_BUILD_SECRET: "test-catalog-secret",
    OPS_SECRET: "test-ops-secret",
    ALLOWED_ORIGINS: "https://arul.hsrutility.com",
    ...overrides,
  } as unknown as Env;
}

/** Build a minimal Hono Context for a route handler. */
export function makeCtx(opts: {
  env: Env;
  token?: string;
  scheme?: string;
  jsonBody?: unknown;
  invalidJson?: boolean;
  /** Request URL. A handler deriving an origin from it throws on undefined -> it is defaulted, never optional.
   *  `c.req.query()` reads its search params -> pass the REAL url for any route that takes query arguments. */
  url?: string;
  /** Path parameters, as Hono would have matched them (e.g. `/w/:id`). */
  params?: Record<string, string>;
}): Context<{ Bindings: Env }> {
  const url = opts.url ?? "https://arul-api.hsrutility.com/test";
  return {
    env: opts.env,
    req: {
      url,
      header: (name: string) =>
        name.toLowerCase() === "authorization" && opts.token != null
          ? `${opts.scheme ?? "Bearer"} ${opts.token}`
          : undefined,
      param: (name: string) => opts.params?.[name],
      query: (name: string) => new URL(url).searchParams.get(name) ?? undefined,
      json: () =>
        opts.invalidJson
          ? Promise.reject(new Error("bad json"))
          : Promise.resolve(opts.jsonBody),
    },
    // The third arg mirrors Hono's -> extra response headers -> keep the signature identical or tests drift from prod
    json: (body: unknown, status = 200, headers?: Record<string, string>) =>
      Response.json(body, headers ? { status, headers } : { status }),
    redirect: (location: string, status = 302) =>
      new Response(null, { status, headers: { location } }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}
