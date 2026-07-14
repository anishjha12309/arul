/**
 * Shared test helpers: an in-memory R2 bucket, a tagged-template SQL mock, a
 * full fake Env carrying per-app SQL handles, and a fetch stub for the rebuild
 * trigger. Not a *.test.ts file, so vitest does not run it directly.
 *
 * DB pattern (copied from the Arul worker tests): handlers obtain the DB via
 * getDb(env, app); each test file mocks ../src/lib/db.js to return the
 * per-app handle stashed on the env as _sql_<slug>. NOTHING here ever touches
 * a real DB, bucket, or network — the fetch stub intercepts rebuild calls.
 */

import { vi } from "vitest";
import type { Env } from "../src/env.js";

// ── In-memory R2 bucket ────────────────────────────────────────────────────────

export interface MockR2 {
  bucket: R2Bucket;
  store: Map<string, { body: string; contentType?: string }>;
  calls: { get: string[]; put: string[]; delete: string[]; head: string[] };
}

export function makeMockR2(
  opts: {
    /** keys whose PUT throws (simulates a mid-batch copy failure) */
    failPutKeys?: string[];
    /** initial objects: key → { body, contentType } */
    initial?: Record<string, { body?: string; contentType?: string }>;
  } = {},
): MockR2 {
  const store = new Map<string, { body: string; contentType?: string }>();
  for (const [k, v] of Object.entries(opts.initial ?? {})) {
    const entry: { body: string; contentType?: string } = { body: v.body ?? "bytes" };
    if (v.contentType !== undefined) entry.contentType = v.contentType;
    store.set(k, entry);
  }
  const failPut = new Set(opts.failPutKeys ?? []);
  const calls: MockR2["calls"] = { get: [], put: [], delete: [], head: [] };

  const bucket = {
    get: vi.fn(async (key: string) => {
      calls.get.push(key);
      const o = store.get(key);
      if (!o) return null;
      return {
        key,
        body: o.body,
        httpMetadata: { contentType: o.contentType },
        text: async () => o.body,
      };
    }),
    put: vi.fn(async (key: string, body: unknown, putOpts?: { httpMetadata?: { contentType?: string } }) => {
      calls.put.push(key);
      if (failPut.has(key)) throw new Error(`simulated put failure: ${key}`);
      const entry: { body: string; contentType?: string } = { body: String(body) };
      const ct = putOpts?.httpMetadata?.contentType;
      if (ct !== undefined) entry.contentType = ct;
      store.set(key, entry);
      return { key };
    }),
    delete: vi.fn(async (key: string) => {
      calls.delete.push(key);
      store.delete(key);
    }),
    head: vi.fn(async (key: string) => {
      calls.head.push(key);
      const o = store.get(key);
      return o ? { key, httpMetadata: { contentType: o.contentType } } : null;
    }),
  } as unknown as R2Bucket;

  return { bucket, store, calls };
}

// ── Tagged-template SQL mock ───────────────────────────────────────────────────

export interface MockSqlHandle {
  sql: unknown;
  /** every tagged-template invocation's args (args[0] = the template strings) */
  capturedArgs: unknown[][];
  beginCalls: number;
}

/**
 * Tagged-template SQL mock: every invocation records its args and resolves
 * `rows`. begin(cb) runs cb with the same tag function (queries inside the
 * transaction are captured too) unless failBegin is set.
 */
export function makeMockSql(
  rows: unknown[],
  opts: { failBegin?: boolean } = {},
): MockSqlHandle {
  const capturedArgs: unknown[][] = [];
  const handle: MockSqlHandle = { sql: null, capturedArgs, beginCalls: 0 };
  const fn = vi.fn((...args: unknown[]) => {
    capturedArgs.push(args);
    return Promise.resolve(rows);
  });
  handle.sql = Object.assign(fn, {
    end: vi.fn().mockResolvedValue(undefined),
    begin: vi.fn(async (cb: (tx: unknown) => unknown) => {
      handle.beginCalls += 1;
      if (opts.failBegin) throw new Error("simulated transaction failure");
      return cb(fn);
    }),
  });
  return handle;
}

/** Text of every captured SQL statement, joined — for "did it bump the version" asserts. */
export function capturedSqlText(handle: MockSqlHandle): string {
  return handle.capturedArgs
    .map((args) => (Array.isArray(args[0]) ? (args[0] as string[]).join("?") : ""))
    .join("\n");
}

// ── Env + execution context ───────────────────────────────────────────────────

export interface TestEnvHandles {
  env: Env;
  pakizaSql: MockSqlHandle;
  arulSql: MockSqlHandle;
  pakizaR2: MockR2;
  arulR2: MockR2;
}

export function makeEnv(
  opts: {
    pakizaRows?: unknown[];
    arulRows?: unknown[];
    arulSql?: MockSqlHandle;
    pakizaSql?: MockSqlHandle;
    arulR2?: MockR2;
    pakizaR2?: MockR2;
    overrides?: Record<string, unknown>;
  } = {},
): TestEnvHandles {
  const pakizaSql = opts.pakizaSql ?? makeMockSql(opts.pakizaRows ?? []);
  const arulSql = opts.arulSql ?? makeMockSql(opts.arulRows ?? []);
  const pakizaR2 = opts.pakizaR2 ?? makeMockR2();
  const arulR2 = opts.arulR2 ?? makeMockR2();

  const env = {
    HYPERDRIVE_PAKIZA: { connectionString: "postgres://pakiza.invalid/db" } as Hyperdrive,
    HYPERDRIVE_ARUL: { connectionString: "postgres://arul.invalid/db" } as Hyperdrive,
    R2_PAKIZA: pakizaR2.bucket,
    R2_ARUL: arulR2.bucket,
    ADMIN_USERNAME: "admin",
    ADMIN_PASSWORD_HASH: "pbkdf2$1$AA==$AA==", // overridden by auth tests
    ADMIN_SESSION_SECRET: "admin-session-secret-at-least-32-bytes!!",
    R2_ACCESS_KEY_ID: "test-r2-key",
    R2_SECRET_ACCESS_KEY: "test-r2-secret",
    R2_ENDPOINT: "https://acct.r2.cloudflarestorage.com",
    ARUL_CATALOG_BUILD_SECRET: "test-arul-catalog-secret",
    PAKIZA_CATALOG_BUILD_SECRET: "test-pakiza-catalog-secret",
    // per-app SQL handles picked up by the ../src/lib/db.js mock
    _sql_pakiza: pakizaSql.sql,
    _sql_arul: arulSql.sql,
    ...(opts.overrides ?? {}),
  } as unknown as Env;

  return { env, pakizaSql, arulSql, pakizaR2, arulR2 };
}

export const execCtx = {
  waitUntil(_p: Promise<unknown>) {},
  passThroughOnException() {},
} as unknown as ExecutionContext;

/**
 * Stub global fetch so NOTHING in a test can reach a real endpoint (Pakiza
 * prod, Arul prod, R2). Returns the vi.fn for call asserts.
 */
export function stubFetch(status = 200): ReturnType<typeof vi.fn> {
  const fn = vi.fn(async () => new Response(JSON.stringify({ ok: status < 300 }), { status }));
  vi.stubGlobal("fetch", fn);
  return fn;
}
