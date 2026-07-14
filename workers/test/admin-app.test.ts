/**
 * Integration test for the CMS auth boundary, exercised through the real Worker
 * (mount + guard + login → cookie → access). The DB is mocked so the dashboard
 * renders without Neon.
 */

import { describe, it, expect, beforeAll, vi } from "vitest";
import { SignJWT } from "jose";
import { makeEnv } from "./_ctx.js";

const SESSION_SECRET = "admin-session-secret-at-least-32-bytes!!";

vi.mock("../src/lib/db.js", () => ({
  getDb: () => {
    const fn: (...a: unknown[]) => Promise<unknown[]> = () =>
      Promise.resolve([
        { wp_total: 1, wp_pub: 1, pending: 0, version: 3 },
      ]);
    return Object.assign(fn, {
      end: () => Promise.resolve(),
      begin: async (cb: (tx: unknown) => unknown) => cb(fn),
    });
  },
}));

import worker from "../src/index.js";
import { requireAdmin } from "../src/admin/auth.js";
import type { Env } from "../src/env.js";
import type { Context, Next } from "hono";

const ctx = {
  waitUntil() {},
  passThroughOnException() {},
} as unknown as ExecutionContext;

function b64(u: Uint8Array): string {
  return btoa(String.fromCharCode(...u));
}
async function makeHash(password: string, iterations = 1000): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
      key,
      32 * 8,
    ),
  );
  return `pbkdf2$${iterations}$${b64(salt)}$${b64(bits)}`;
}

let env: Env;

beforeAll(async () => {
  env = makeEnv({
    ADMIN_USERNAME: "admin",
    ADMIN_PASSWORD_HASH: await makeHash("testpassword123"),
    ADMIN_SESSION_SECRET: SESSION_SECRET,
  });
});

/** Mint an admin session cookie, optionally signed with the wrong secret. */
async function sessionCookie(secret = SESSION_SECRET): Promise<string> {
  const token = await new SignJWT({ adm: true })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(secret));
  return `arul_admin=${token}`;
}

const get = (path: string, headers: Record<string, string> = {}) =>
  worker.fetch(new Request(`https://api.hsrutility.com${path}`, { headers }), env, ctx);

describe("CMS auth boundary", () => {
  it("serves the login page unauthenticated", async () => {
    const res = await get("/admin/login");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("Sign in");
  });

  it("redirects an unauthenticated dashboard request to /admin/login", async () => {
    const res = await get("/admin");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin/login");
  });

  it("rejects wrong credentials with 401 and no session cookie", async () => {
    const res = await worker.fetch(
      new Request("https://api.hsrutility.com/admin/login", {
        method: "POST",
        body: new URLSearchParams({ username: "admin", password: "nope" }),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(401);
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  it("accepts correct credentials and redirects to the dashboard", async () => {
    const login = await worker.fetch(
      new Request("https://api.hsrutility.com/admin/login", {
        method: "POST",
        body: new URLSearchParams({ username: "admin", password: "testpassword123" }),
      }),
      env,
      ctx,
    );
    expect(login.status).toBe(302);
    expect(login.headers.get("location")).toBe("/admin");
  });

  // The test env strips the (forbidden) `cookie` request header from fetch, so
  // session acceptance is verified by calling the guard directly with a context.
  function guardCtx(cookieHeader: string | null) {
    return {
      env,
      req: {
        // requireAdmin checks the HX-Request header; getCookie reads raw.headers.
        header: () => undefined,
        raw: { headers: { get: (n: string) => (n === "Cookie" ? cookieHeader : null) } },
      },
      redirect: (loc: string) => new Response(null, { status: 302, headers: { location: loc } }),
      header: () => {},
      body: (_b: unknown, s: number) => new Response(null, { status: s }),
    } as unknown as Context<{ Bindings: Env }>;
  }

  it("requireAdmin lets a valid session cookie through", async () => {
    const token = (await sessionCookie()).split("=")[1]!;
    let nexted = false;
    const next: Next = async () => {
      nexted = true;
    };
    const res = await requireAdmin(guardCtx(`arul_admin=${token}`), next);
    expect(nexted).toBe(true);
    expect(res).toBeUndefined();
  });

  it("requireAdmin redirects a missing or wrong-secret session", async () => {
    const next: Next = async () => {};
    const missing = await requireAdmin(guardCtx(null), next);
    expect((missing as Response).status).toBe(302);

    const badToken = (await sessionCookie("not-the-real-secret-aaaaaaaaaaaaaaaa")).split("=")[1]!;
    const bad = await requireAdmin(guardCtx(`arul_admin=${badToken}`), next);
    expect((bad as Response).status).toBe(302);
  });
});
