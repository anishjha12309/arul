/**
 * Shared test helpers for route-handler tests: an in-memory KV, a tagged-template
 * SQL mock (returns the same rows for every query), a full fake Env, and a
 * minimal Hono Context. Not a *.test.ts file, so vitest does not run it directly.
 *
 * Handlers obtain the DB via getDb(env); each test file mocks ../src/lib/db.js
 * to return env._testSql, which is the sql produced by makeMockSql here.
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
    // Minimal R2 binding stub: head() resolves to a truthy object (upload
    // "exists"), delete() is a no-op. Override per-test to simulate a missing
    // object (head: async () => null).
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
}): Context<{ Bindings: Env }> {
  return {
    env: opts.env,
    req: {
      header: (name: string) =>
        name.toLowerCase() === "authorization" && opts.token != null
          ? `${opts.scheme ?? "Bearer"} ${opts.token}`
          : undefined,
      json: () =>
        opts.invalidJson
          ? Promise.reject(new Error("bad json"))
          : Promise.resolve(opts.jsonBody),
    },
    json: (body: unknown, status = 200) => Response.json(body, { status }),
    executionCtx: { waitUntil: (_p: Promise<unknown>) => {} },
  } as unknown as Context<{ Bindings: Env }>;
}
