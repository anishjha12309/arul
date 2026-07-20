/**
 * Arul API Worker — entry point.
 *
 * Framework: Hono ^4 (Cloudflare Workers-native, ~12kB, built-in CORS + error
 * handling, TypeScript-first). Chosen over itty-router because this project
 * needs middleware (CORS, auth), typed contexts, and built-in error envelopes —
 * not just a router. Hono is also 2× faster than itty-router in benchmarks.
 * See: https://hono.dev/docs/getting-started/cloudflare-workers
 *
 * Routes:
 *   POST /auth/login
 *   POST /auth/refresh
 *   POST /auth/logout
 *   POST /media/signed-url
 *   POST /media/upload-url
 *   POST /media/confirm-upload
 *   POST /payments/initiate     — start PhonePe PENNY_DROP Autopay mandate
 *   POST /payments/webhook      — PhonePe S2S callback (idempotent)
 *   POST /payments/status       — live subscription state reconciliation
 *   GET  /me
 *   DELETE /me                  — delete account (mandate revoke + trial tombstone)
 *   GET  /me/subscription
 *   GET  /me/submissions
 *   GET  /me/referrals
 *   POST /internal/build-catalog
 *   POST /internal/sweep-submissions — reclaim orphaned R2 submission objects
 *   POST /internal/sweep-canonical  — reclaim orphaned canonical media objects
 *   POST /internal/run-redemptions  — force notify+execute (testing)
 *
 * Scheduled handlers:
 *   "0 * * * *"  — hourly: catalog rebuild (no-op if nothing changed) +
 *                           orphaned-submission sweep + canonical-media sweep +
 *                           autopay notify/execute scan
 *
 * Error envelope: { "error": { "code": string, "message": string } }
 */

import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./env.js";
import { handleLogin, handleRefresh, handleLogout } from "./routes/auth.js";
import {
  handleSignedUrl,
  handleUploadUrl,
  handleConfirmUpload,
} from "./routes/media.js";
import {
  handleInitiate,
  handleWebhook,
  handleStatus,
  handleCancel,
  handleCallback,
} from "./routes/payments.js";
import {
  handleMe,
  handleUpdateProfile,
  handleDeleteAccount,
  handleMeSubscription,
  handleMeSubmissions,
  handleMeReferrals,
} from "./routes/me.js";
import {
  handleBuildCatalog,
  handleSweepSubmissions,
  handleSweepCanonical,
  handleRunRedemptions,
  handleRefund,
} from "./routes/internal.js";
import { buildCatalog } from "./cron/build-catalog.js";
import { sweepSubmissions } from "./cron/sweep-submissions.js";
import { sweepCanonical } from "./cron/sweep-canonical.js";
import { runAutopayNotify } from "./cron/autopay-notify.js";

// ── App ───────────────────────────────────────────────────────────────────────

const app = new Hono<{ Bindings: Env }>();

// ── CORS ──────────────────────────────────────────────────────────────────────
// Allows requests from browser-based origins listed in ALLOWED_ORIGINS.
// The Flutter native app is unaffected by CORS (not a browser).
app.use("/*", async (c, next) => {
  const allowed = (c.env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);

  const corsMiddleware = cors({
    origin: allowed.length > 0 ? allowed : "*",
    allowMethods: ["GET", "POST", "DELETE", "OPTIONS"],
    allowHeaders: ["Authorization", "Content-Type"],
    maxAge: 86400,
  });
  return corsMiddleware(c, next);
});

// ── Auth routes ───────────────────────────────────────────────────────────────
app.post("/auth/login", handleLogin);
app.post("/auth/refresh", handleRefresh);
app.post("/auth/logout", handleLogout);

// ── Media routes (all gated) ──────────────────────────────────────────────────
app.post("/media/signed-url", handleSignedUrl);
app.post("/media/upload-url", handleUploadUrl);
app.post("/media/confirm-upload", handleConfirmUpload);

// ── Payment routes (PhonePe Autopay v2) ───────────────────────────────────────
app.post("/payments/initiate", handleInitiate);   // JWT — start ₹2 PENNY_DROP mandate
app.post("/payments/webhook", handleWebhook);      // S2S callback (callback-auth verified)
app.post("/payments/status", handleStatus);        // JWT — reconcile live subscription state
app.post("/payments/cancel", handleCancel);        // JWT — revoke mandate (Manage Subscription)
app.get("/payments/callback", handleCallback);     // PhonePe post-mandate browser redirect

// ── Me routes (all gated, scoped to verified sub) ─────────────────────────────
app.get("/me", handleMe);
app.post("/me/profile", handleUpdateProfile);
app.delete("/me", handleDeleteAccount); // revoke mandate → tombstone → cascade delete
app.get("/me/subscription", handleMeSubscription);
app.get("/me/submissions", handleMeSubmissions);
app.get("/me/referrals", handleMeReferrals);

// ── Internal routes ───────────────────────────────────────────────────────────
app.post("/internal/build-catalog", handleBuildCatalog);
app.post("/internal/sweep-submissions", handleSweepSubmissions);
app.post("/internal/sweep-canonical", handleSweepCanonical);
app.post("/internal/run-redemptions", handleRunRedemptions); // testing: force notify+execute
app.post("/internal/refund", handleRefund);                  // operator/support: ₹199 refund

// Authoring lives in the unified CMS worker (hsr-cms), not here — see README.
// It reaches this worker via the ARUL_API service binding + /internal/build-catalog.

// ── Global error handler ──────────────────────────────────────────────────────
app.onError((err, c) => {
  console.error("[worker] Unhandled error:", err);
  return c.json(
    { error: { code: "server_error", message: "Internal server error" } },
    500,
  );
});

// ── 404 handler ───────────────────────────────────────────────────────────────
app.notFound((c) => {
  return c.json(
    { error: { code: "not_found", message: `Route not found: ${c.req.method} ${c.req.path}` } },
    404,
  );
});

// ── Scheduled handler (CRON) ──────────────────────────────────────────────────

interface ScheduledEvent {
  cron: string;
}

type WorkerType = {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => Promise<Response>;
  scheduled: (event: ScheduledEvent, env: Env, ctx: ExecutionContext) => Promise<void>;
};

const worker: WorkerType = {
  fetch: async (req, env, ctx) => app.fetch(req, env, ctx),

  async scheduled(event, env, ctx) {
    // "0 * * * *" — hourly: catalog rebuild + autopay notify/execute
    if (event.cron === "0 * * * *") {
      console.log("[cron] Running hourly catalog rebuild");
      ctx.waitUntil(
        buildCatalog(env, null).then(async (results) => {
          console.log("[cron] Catalog rebuild complete:", JSON.stringify(results));
          // Canonical-media sweep runs strictly AFTER a FULLY SUCCESSFUL
          // rebuild — if any scope failed, its stale catalog pages may still
          // reference a just-unreferenced object, and deleting the bytes then
          // would break the live feed (backstop for abandoned CMS uploads +
          // lost delete/replace cleanups).
          const anyScopeError = Object.values(results).some(
            (r) => r && typeof r === "object" && "error" in r,
          );
          if (anyScopeError) {
            console.warn("[cron] Skipping canonical sweep — a catalog scope failed to rebuild");
            return;
          }
          try {
            const result = await sweepCanonical(env);
            console.log("[cron] Canonical sweep complete:", JSON.stringify(result));
          } catch (err) {
            console.error("[cron] Canonical sweep failed:", err);
          }
        }).catch((err: unknown) => {
          console.error("[cron] Catalog rebuild failed:", err);
        }),
      );

      // Reclaim orphaned user-submission objects from R2 (backstop for the
      // inline delete-on-approve/reject). No-op when nothing is orphaned.
      ctx.waitUntil(
        sweepSubmissions(env).then((result) => {
          console.log("[cron] Submission sweep complete:", JSON.stringify(result));
        }).catch((err: unknown) => {
          console.error("[cron] Submission sweep failed:", err);
        }),
      );

      // Autopay: notify 24h before each debit, then execute at/after next_debit_at.
      console.log("[cron] Running autopay notify/execute scan");
      ctx.waitUntil(
        runAutopayNotify(env).catch((err: unknown) => {
          console.error("[cron] Autopay notify failed:", err);
        }),
      );
    }
  },
};

export default worker;
