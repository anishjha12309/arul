/**
 * Arul CMS — admin sub-app, mounted at /admin in src/index.ts.
 *
 * Single-operator, server-rendered (Hono JSX + HTMX). All routes except
 * /admin/login and /admin/logout are guarded by a session cookie (see auth.ts).
 * Content writes go through this Worker (honoring "DB reached only from Workers"
 * — CLAUDE.md §2); media bytes upload directly browser→R2 via presigned PUT.
 */

import { Hono } from "hono";
import type { Env } from "../env.js";
import { getDb } from "../lib/db.js";
import { Layout, LoginView, PageHead, StatCard } from "./ui.js";
import {
  clearLoginFails,
  clearSession,
  getLoginFails,
  issueSession,
  LOGIN_MAX_FAILS,
  recordLoginFail,
  requireAdmin,
  verifyPassword,
} from "./auth.js";
import { handleAdminUploadUrl } from "./media.js";
import { wallpapersApp } from "./wallpapers.js";
import { submissionsApp } from "./submissions.js";
import { configApp } from "./config.js";

export const adminApp = new Hono<{ Bindings: Env }>();

// ── Guard: protect everything except the login/logout endpoints ──────────────
// Accept both the mounted (/admin/login) and bare (/login) path forms so the
// exemption is robust regardless of how Hono surfaces the path under route().
adminApp.use("/*", async (c, next) => {
  const p = c.req.path;
  if (
    p === "/admin/login" ||
    p === "/login" ||
    p === "/admin/logout" ||
    p === "/logout"
  ) {
    return next();
  }
  return requireAdmin(c, next);
});

// ── Login ─────────────────────────────────────────────────────────────────────
adminApp.get("/login", (c) => c.html(<LoginView />));

adminApp.post("/login", async (c) => {
  const ip = c.req.header("cf-connecting-ip") ?? "unknown";

  if ((await getLoginFails(c.env, ip)) >= LOGIN_MAX_FAILS) {
    return c.html(
      <LoginView error="Too many attempts. Wait ~15 minutes and try again." />,
      429,
    );
  }

  const form = await c.req.parseBody();
  const username = typeof form.username === "string" ? form.username : "";
  const password = typeof form.password === "string" ? form.password : "";

  const userOk = username.length > 0 && username === c.env.ADMIN_USERNAME;
  const passOk = await verifyPassword(password, c.env.ADMIN_PASSWORD_HASH);

  if (!userOk || !passOk) {
    await recordLoginFail(c.env, ip);
    return c.html(<LoginView error="Invalid username or password." />, 401);
  }

  await clearLoginFails(c.env, ip);
  await issueSession(c, username);
  return c.redirect("/admin");
});

adminApp.post("/logout", (c) => {
  clearSession(c);
  return c.redirect("/admin/login");
});

// ── Admin media presign (shared by authoring forms) ──────────────────────────
adminApp.post("/media/upload-url", handleAdminUploadUrl);

// ── Feature sub-apps ──────────────────────────────────────────────────────────
adminApp.route("/wallpapers", wallpapersApp);
adminApp.route("/submissions", submissionsApp);
adminApp.route("/config", configApp);

// ── Dashboard ───────────────────────────────────────────────────────────────
adminApp.get("/", async (c) => {
  const sql = getDb(c.env);
  let wpPub = "0";
  let wpTotal = "0";
  let pending = "0";
  let version = "0";
  let inSync = true;
  let dbError = false;

  try {
    const rows = await sql`
      SELECT
        (SELECT count(*) FROM wallpapers)                              AS wp_total,
        (SELECT count(*) FROM wallpapers WHERE is_published)           AS wp_pub,
        (SELECT count(*) FROM content_submissions WHERE status='pending') AS pending,
        (SELECT content_version FROM app_config WHERE id=1)            AS version
    `;
    const r = rows[0] ?? {};
    wpTotal = String(r.wp_total ?? "0");
    wpPub = String(r.wp_pub ?? "0");
    pending = String(r.pending ?? "0");
    version = r.version === null || r.version === undefined ? "0" : String(r.version);

    // The catalog is "in sync" when the last-built version (KV) matches the
    // current content_version. A mismatch means a rebuild is pending.
    const lastBuilt = await c.env.KV.get("catalog_version:wallpapers");
    inSync = lastBuilt !== null && lastBuilt === version;
  } catch (err) {
    console.error("[admin/dashboard] DB error:", err);
    dbError = true;
  } finally {
    c.executionCtx.waitUntil(sql.end());
  }

  return c.html(
    <Layout title="Dashboard" active="dashboard">
      <PageHead title="Dashboard" sub="Content overview" />
      {dbError ? (
        <div class="note danger">Could not reach the database. Check Hyperdrive / Neon.</div>
      ) : null}
      <div class="grid">
        <StatCard n={wpPub} label="Published wallpapers" hint={`${wpTotal} total`} />
        <StatCard n={pending} label="Pending submissions" hint="awaiting review" />
        <div class="card stat">
          <div class="n">v{version}</div>
          <div class="l">Catalog version</div>
          <div class="hint">
            {inSync ? (
              <span class="badge ok">edge in sync</span>
            ) : (
              <span class="badge warn">rebuild pending</span>
            )}
          </div>
        </div>
      </div>
      <div class="card" style="margin-top:18px">
        <div class="row" style="justify-content:space-between">
          <div>
            <div class="card-title">Quick actions</div>
            <div class="card-desc">Authoring and moderation tools.</div>
          </div>
          <div class="row">
            <a class="btn sec" href="/admin/wallpapers">
              Wallpapers
            </a>
            <a class="btn" href="/admin/submissions">
              Review submissions{pending !== "0" ? ` (${pending})` : ""}
            </a>
          </div>
        </div>
      </div>
    </Layout>,
  );
});
