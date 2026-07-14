/**
 * HSR unified CMS — standalone Cloudflare Worker managing content for TWO apps
 * (Pakiza + Arul) from one login. Server-rendered (Hono JSX + HTMX); all
 * /admin routes except /admin/login and /admin/logout are guarded by the
 * hsr_cms session cookie.
 *
 * Routes (the CMS is mounted under /admin — route api.hsrutility.com/admin*):
 *   GET/POST /admin/login · POST /admin/logout
 *   GET  /admin (and /admin/)             — app picker + combined dashboard
 *   POST /admin/{app}/media/upload-url    — presigned PUT to the app's bucket
 *   /admin/pakiza/{wallpapers,ringtones,submissions,config}
 *   /admin/arul/{wallpapers,submissions,config}
 *   /admin/arul/transfer                  — category transfer tool (Arul only)
 *
 *   POST /payments/webhook                — PhonePe S2S dispatcher (NO session
 *     auth; route api.hsrutility.com/payments/webhook*). PhonePe sends both
 *     apps' callbacks to one URL; src/payments-dispatch.ts relays each event
 *     verbatim to ARUL_API (merchant id "DKS_…") or PAKIZA_API (everything
 *     else — Pakiza is the incumbent registrant).
 *
 * Every content mutation bumps that app's app_config.content_version in the
 * same transaction as the row write, then fires the app Worker's
 * POST /internal/build-catalog (per-app bearer secret). A failed rebuild never
 * rolls back the DB write — the page shows a "rebuild failed, retry" banner
 * and the app Worker's hourly cron self-heals.
 */

import { Hono } from "hono";
import { ADMIN_BASE, type Env } from "./env.js";
import { PAKIZA, ARUL } from "./registry.js";
import { requireAdmin } from "./auth.js";
import { makeUploadUrlHandler } from "./media.js";
import { handlePaymentsWebhook } from "./payments-dispatch.js";
import { handleLoginPage, handleLoginPost, handleLogout } from "./pages/login.js";
import { handleDashboard } from "./pages/dashboard.js";
import { makeWallpapersApp } from "./pages/wallpapers.js";
import { makeRingtonesApp } from "./pages/ringtones.js";
import { makeSubmissionsApp } from "./pages/submissions.js";
import { makeConfigApp } from "./pages/config.js";
import { makeTransferApp } from "./pages/transfer.js";

// ── Admin sub-app: EVERY CMS page lives under /admin ──────────────────────────
const admin = new Hono<{ Bindings: Env }>().basePath(ADMIN_BASE);

// Guard: protect /admin/* except the login/logout endpoints. c.req.path is the
// FULL request path here (basePath does not strip it), hence the prefix.
admin.use("/*", async (c, next) => {
  const p = c.req.path;
  if (p === `${ADMIN_BASE}/login` || p === `${ADMIN_BASE}/logout`) return next();
  return requireAdmin(c, next);
});

// ── Login / logout ────────────────────────────────────────────────────────────
admin.get("/login", handleLoginPage);
admin.post("/login", handleLoginPost);
admin.post("/logout", handleLogout);

// ── Combined dashboard (GET /admin — the root app's strict:false also routes
//    GET /admin/ here) ─────────────────────────────────────────────────────────
admin.get("/", handleDashboard);

// ── Per-app media presign (used by the authoring forms' uploader) ─────────────
admin.post("/pakiza/media/upload-url", makeUploadUrlHandler(PAKIZA));
admin.post("/arul/media/upload-url", makeUploadUrlHandler(ARUL));

// ── Pakiza (wallpapers + ringtones + submissions + config) ────────────────────
admin.route("/pakiza/wallpapers", makeWallpapersApp(PAKIZA));
admin.route("/pakiza/ringtones", makeRingtonesApp(PAKIZA));
admin.route("/pakiza/submissions", makeSubmissionsApp(PAKIZA));
admin.route("/pakiza/config", makeConfigApp(PAKIZA));

// ── Arul (wallpapers + submissions + config + category transfer) ──────────────
admin.route("/arul/wallpapers", makeWallpapersApp(ARUL));
admin.route("/arul/submissions", makeSubmissionsApp(ARUL));
admin.route("/arul/config", makeConfigApp(ARUL));
admin.route("/arul/transfer", makeTransferApp(ARUL));

// ── Root app: /payments/webhook (session-free) + the /admin sub-app ───────────
// strict:false so GET /admin/ matches the /admin dashboard route too.
const app = new Hono<{ Bindings: Env }>({ strict: false });

// PhonePe S2S dispatcher — POST only (GET → Hono's default 404).
app.post("/payments/webhook", handlePaymentsWebhook);

app.route("/", admin);

// ── Global error handler ──────────────────────────────────────────────────────
app.onError((err, c) => {
  console.error("[cms] unhandled error:", err);
  return c.text("Internal error", 500);
});

export default app;
