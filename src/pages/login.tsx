/**
 * Login / logout handlers (copied from the reference CMS app.tsx; the throttle
 * is in-memory — see auth.ts). Split out of index.ts so the entrypoint stays a
 * plain .ts file while these render JSX.
 */

import type { Context } from "hono";
import { ADMIN_BASE, type Env } from "../env.js";
import { LoginView } from "../ui.js";
import {
  clearLoginFails,
  clearSession,
  getLoginFails,
  issueSession,
  LOGIN_MAX_FAILS,
  recordLoginFail,
  verifyPassword,
} from "../auth.js";

type Ctx = Context<{ Bindings: Env }>;

export function handleLoginPage(c: Ctx): Response | Promise<Response> {
  return c.html(<LoginView />);
}

export async function handleLoginPost(c: Ctx): Promise<Response> {
  const ip = c.req.header("cf-connecting-ip") ?? "unknown";

  if (getLoginFails(ip) >= LOGIN_MAX_FAILS) {
    return c.html(<LoginView error="Too many attempts. Wait ~15 minutes and try again." />, 429);
  }

  const form = await c.req.parseBody();
  const username = typeof form.username === "string" ? form.username : "";
  const password = typeof form.password === "string" ? form.password : "";

  const userOk = username.length > 0 && username === c.env.ADMIN_USERNAME;
  const passOk = await verifyPassword(password, c.env.ADMIN_PASSWORD_HASH);

  if (!userOk || !passOk) {
    recordLoginFail(ip);
    return c.html(<LoginView error="Invalid username or password." />, 401);
  }

  clearLoginFails(ip);
  await issueSession(c, username);
  return c.redirect(ADMIN_BASE);
}

export function handleLogout(c: Ctx): Response {
  clearSession(c);
  return c.redirect(`${ADMIN_BASE}/login`);
}
