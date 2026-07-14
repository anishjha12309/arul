/**
 * CMS admin authentication — single-operator model.
 *
 * One username + password, stored as Worker secrets. The plaintext password is
 * NEVER stored: ADMIN_PASSWORD_HASH is a PBKDF2-HMAC-SHA256 digest
 * ("pbkdf2$<iters>$<saltB64>$<hashB64>", see scripts/hash-admin-password.mjs).
 * On login we recompute the digest and constant-time compare, then issue a
 * short-lived signed session cookie (HS256 via jose, using ADMIN_SESSION_SECRET
 * — deliberately separate from the app's JWT_SECRET so an admin session can
 * never be confused with a user access token).
 *
 * This is intentionally NOT the app's identity JWT: the operator has no users.id
 * row, and role/entitlement must never live in the app token (see lib/jwt.ts).
 * Brute-force is bounded by a per-IP KV counter.
 */

import type { Context, Next } from "hono";
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import { SignJWT, jwtVerify } from "jose";
import type { Env } from "../env.js";

export const SESSION_COOKIE = "arul_admin";
const SESSION_TTL_SECONDS = 12 * 60 * 60; // 12h
export const LOGIN_MAX_FAILS = 10;
const LOGIN_FAIL_WINDOW = 15 * 60; // 15 min

type AdminCtx = Context<{ Bindings: Env }>;

// ── Password hashing (PBKDF2-HMAC-SHA256 over Web Crypto) ─────────────────────

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function pbkdf2(
  password: string,
  salt: Uint8Array,
  iterations: number,
  lenBytes: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    key,
    lenBytes * 8,
  );
  return new Uint8Array(bits);
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/** Verify a plaintext password against a stored "pbkdf2$iters$salt$hash" digest. */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = (stored ?? "").split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = parseInt(parts[1]!, 10);
  if (!Number.isFinite(iterations) || iterations < 1) return false;
  let salt: Uint8Array;
  let expected: Uint8Array;
  try {
    salt = b64ToBytes(parts[2]!);
    expected = b64ToBytes(parts[3]!);
  } catch {
    return false;
  }
  if (expected.length === 0) return false;
  const actual = await pbkdf2(password, salt, iterations, expected.length);
  return constantTimeEqual(actual, expected);
}

// ── Session cookie (HS256 via jose) ───────────────────────────────────────────

function sessionKey(secret: string): Uint8Array {
  return new TextEncoder().encode(secret);
}

async function verifySession(env: Env, token: string): Promise<boolean> {
  try {
    const { payload } = await jwtVerify(token, sessionKey(env.ADMIN_SESSION_SECRET), {
      algorithms: ["HS256"],
    });
    return payload.adm === true;
  } catch {
    return false;
  }
}

/** Sign a session token and set it as a hardened cookie scoped to /admin. */
export async function issueSession(c: AdminCtx, username: string): Promise<void> {
  const token = await new SignJWT({ adm: true, usr: username })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .sign(sessionKey(c.env.ADMIN_SESSION_SECRET));

  // Always set Secure on any real host so the session can never be sent over
  // plaintext (don't derive it from the request scheme — that lets an http
  // downgrade strip Secure). Only exempt local dev where there is no TLS.
  const host = new URL(c.req.url).hostname;
  const secure = host !== "localhost" && host !== "127.0.0.1";
  setCookie(c, SESSION_COOKIE, token, {
    httpOnly: true,
    secure,
    sameSite: "Lax",
    path: "/admin",
    maxAge: SESSION_TTL_SECONDS,
  });
}

export function clearSession(c: AdminCtx): void {
  deleteCookie(c, SESSION_COOKIE, { path: "/admin" });
}

/**
 * Guard for protected /admin routes. Exempt paths (login/logout) are handled by
 * the caller. HTMX requests get an HX-Redirect header (fetch won't follow a 302
 * into a navigation); plain navigations get a normal 302.
 */
export async function requireAdmin(c: AdminCtx, next: Next): Promise<Response | void> {
  const token = getCookie(c, SESSION_COOKIE);
  if (token && (await verifySession(c.env, token))) {
    await next();
    return;
  }
  if (c.req.header("HX-Request") === "true") {
    c.header("HX-Redirect", "/admin/login");
    return c.body(null, 401);
  }
  return c.redirect("/admin/login");
}

// ── Login brute-force throttle (per-IP, KV) ───────────────────────────────────
// Best-effort only: KV has no atomic increment, so a burst of concurrent
// attempts can under-count (read-modify-write race) and slip past the cap. That
// is acceptable here because the real cost gate is the 210k-iteration PBKDF2 per
// guess plus the single-operator model; if multi-admin or a public surface is
// ever added, move this counter to a Durable Object (atomic increment + alarm).

function failKey(ip: string): string {
  return `admin_login_fail:${ip}`;
}

export async function getLoginFails(env: Env, ip: string): Promise<number> {
  const v = await env.KV.get(failKey(ip));
  return v ? parseInt(v, 10) || 0 : 0;
}

export async function recordLoginFail(env: Env, ip: string): Promise<void> {
  const cur = await getLoginFails(env, ip);
  await env.KV.put(failKey(ip), String(cur + 1), { expirationTtl: LOGIN_FAIL_WINDOW });
}

export async function clearLoginFails(env: Env, ip: string): Promise<void> {
  await env.KV.delete(failKey(ip));
}
