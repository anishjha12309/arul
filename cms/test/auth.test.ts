/**
 * CMS auth boundary, exercised through the real Worker (guard + login →
 * hsr_cms cookie → access). Both apps' DBs are mocked so the dashboard renders
 * without Neon; global fetch is stubbed so nothing can reach a real endpoint.
 */

import { describe, it, expect, beforeAll, beforeEach, vi } from "vitest";
import { SignJWT } from "jose";
import { makeEnv, execCtx, stubFetch } from "./_ctx.js";
import type { Env } from "../src/env.js";
import type { AppDef } from "../src/registry.js";

const SESSION_SECRET = "admin-session-secret-at-least-32-bytes!!";

vi.mock("../src/lib/db.js", () => ({
  getDb: (env: Env, app: AppDef) =>
    (env as unknown as Record<string, unknown>)[`_sql_${app.slug}`],
}));

import worker from "../src/index.js";
import { issueSession, requireAdmin, verifyPassword, SESSION_COOKIE } from "../src/auth.js";
import type { Context, Next } from "hono";

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
  const handles = makeEnv({
    pakizaRows: [{ wp_total: 1, wp_pub: 1, rt_total: 2, rt_pub: 2, pending: 0, version: 3 }],
    arulRows: [{ wp_total: 4, wp_pub: 4, pending: 1, version: 7 }],
    overrides: { ADMIN_PASSWORD_HASH: await makeHash("testpassword123") },
  });
  env = handles.env;
});

beforeEach(() => {
  stubFetch();
});

const get = (path: string, headers: Record<string, string> = {}) =>
  worker.fetch(new Request(`https://hsr-cms.example.com${path}`, { headers }), env, execCtx);

describe("verifyPassword", () => {
  it("accepts the correct password and rejects wrong/malformed input", async () => {
    const hash = await makeHash("correct horse battery");
    expect(await verifyPassword("correct horse battery", hash)).toBe(true);
    expect(await verifyPassword("wrong password", hash)).toBe(false);
    expect(await verifyPassword("x", "")).toBe(false);
    expect(await verifyPassword("x", "not-a-hash")).toBe(false);
    expect(await verifyPassword("x", "bcrypt$1000$a$b")).toBe(false);
  });
});

describe("CMS auth boundary", () => {
  it("serves the login page unauthenticated at /admin/login", async () => {
    const res = await get("/admin/login");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Sign in");
    expect(html).toContain('action="/admin/login"');
  });

  it("redirects an unauthenticated dashboard request (with and without trailing slash) to /admin/login", async () => {
    for (const path of ["/admin", "/admin/"]) {
      const res = await get(path);
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe("/admin/login");
    }
  });

  it("redirects unauthenticated app routes (both apps) to /admin/login", async () => {
    for (const path of ["/admin/pakiza/wallpapers", "/admin/arul/wallpapers", "/admin/arul/transfer"]) {
      const res = await get(path);
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe("/admin/login");
    }
  });

  it("rejects wrong credentials with 401 and no session cookie", async () => {
    const res = await worker.fetch(
      new Request("https://hsr-cms.example.com/admin/login", {
        method: "POST",
        body: new URLSearchParams({ username: "admin", password: "nope" }),
      }),
      env,
      execCtx,
    );
    expect(res.status).toBe(401);
    expect(res.headers.get("set-cookie")).toBeNull();
  });

  it("accepts correct credentials and redirects to the /admin dashboard", async () => {
    const login = await worker.fetch(
      new Request("https://hsr-cms.example.com/admin/login", {
        method: "POST",
        body: new URLSearchParams({ username: "admin", password: "testpassword123" }),
      }),
      env,
      execCtx,
    );
    expect(login.status).toBe(302);
    expect(login.headers.get("location")).toBe("/admin");
    // happy-dom strips the (forbidden) Set-Cookie response header from fetch,
    // so cookie ACCEPTANCE is verified via requireAdmin below; the cookie name
    // contract is pinned here.
    expect(SESSION_COOKIE).toBe("hsr_cms");
  });

  // The test env strips the (forbidden) `cookie` request header from fetch, so
  // session acceptance is verified by calling the guard directly with a context.
  function guardCtx(cookieHeader: string | null) {
    return {
      env,
      req: {
        header: () => undefined,
        raw: { headers: { get: (n: string) => (n === "Cookie" ? cookieHeader : null) } },
      },
      redirect: (loc: string) => new Response(null, { status: 302, headers: { location: loc } }),
      header: () => {},
      body: (_b: unknown, s: number) => new Response(null, { status: s }),
    } as unknown as Context<{ Bindings: Env }>;
  }

  async function sessionToken(secret = SESSION_SECRET): Promise<string> {
    return new SignJWT({ adm: true })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("1h")
      .sign(new TextEncoder().encode(secret));
  }

  it("requireAdmin lets a valid hsr_cms session through", async () => {
    const token = await sessionToken();
    let nexted = false;
    const next: Next = async () => {
      nexted = true;
    };
    const res = await requireAdmin(guardCtx(`${SESSION_COOKIE}=${token}`), next);
    expect(nexted).toBe(true);
    expect(res).toBeUndefined();
  });

  it("requireAdmin redirects a missing or wrong-secret session to /admin/login", async () => {
    const next: Next = async () => {};
    const missing = await requireAdmin(guardCtx(null), next);
    expect((missing as Response).status).toBe(302);
    expect((missing as Response).headers.get("location")).toBe("/admin/login");

    const badToken = await sessionToken("not-the-real-secret-aaaaaaaaaaaaaaaa");
    const bad = await requireAdmin(guardCtx(`${SESSION_COOKIE}=${badToken}`), next);
    expect((bad as Response).status).toBe(302);
    expect((bad as Response).headers.get("location")).toBe("/admin/login");
  });

  it("issueSession scopes the hsr_cms cookie to Path=/admin", async () => {
    const headers: string[] = [];
    const ctx = {
      env,
      req: { url: "https://api.hsrutility.com/admin/login" },
      header: (_name: string, value: string) => {
        headers.push(value);
      },
      res: new Response(null),
    } as unknown as Context<{ Bindings: Env }>;

    await issueSession(ctx, "admin");
    const cookie = headers.find((h) => h.startsWith(`${SESSION_COOKIE}=`)) ?? "";
    expect(cookie).toContain("Path=/admin");
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
  });
});
