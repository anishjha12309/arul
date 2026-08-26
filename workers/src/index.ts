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
 *   GET  /.well-known/assetlinks.json — App Links verification (public)
 *   GET  /w/:id                 — wallpaper share/ad link → Play + referrer (public)
 *   GET  /r/:id                 — ringtone ad link → Play + referrer (public)
 *   POST /auth/login
 *   POST /auth/refresh
 *   POST /auth/logout
 *   POST /media/signed-url
 *   POST /media/upload-url
 *   POST /media/confirm-upload
 *   POST /payments/initiate     — start Autopay mandate: PENNY_DROP ₹2 when
 *                                 trial-eligible, else TRANSACTION ₹199
 *   POST /payments/webhook      — PhonePe S2S callback (idempotent)
 *   POST /payments/status       — live subscription state reconciliation
 *   POST /payments/cancel       — revoke mandate (Manage Subscription)
 *   POST /payments/abandon      — release a claimed setup after SDK cancel
 *   GET  /payments/callback     — PhonePe post-mandate browser redirect
 *   GET  /me
 *   POST /me/profile            — update display name
 *   DELETE /me                  — delete account (mandate revoke + trial tombstone)
 *   GET  /me/subscription
 *   GET  /me/submissions
 *   GET  /me/referrals
 *   POST /internal/build-catalog
 *   POST /internal/sweep-submissions — reclaim orphaned R2 submission objects
 *   POST /internal/sweep-canonical  — reclaim orphaned canonical media objects
 *   POST /internal/run-redemptions  — force notify+execute (testing)
 *   POST /internal/refund           — operator/support ₹199 refund
 *
 * Scheduled handlers:
 *   "0 * * * *"   — hourly: catalog rebuild (no-op if nothing changed) +
 *                            on-change canonical-media sweep + autopay
 *                            notify/execute scan
 *   "30 21 * * *" — daily (21:30 UTC = 03:00 IST, off-peak): unconditional
 *                            canonical-media sweep + orphaned-submission sweep
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
  handleAssetLinks,
  handleWallpaperLink,
  handleRingtoneLink,
} from "./routes/deeplink.js";
import {
  handleInitiate,
  handleWebhook,
  handleStatus,
  handleCancel,
  handleAbandon,
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
import { buildCatalog, refreshPopularityOrder } from "./cron/build-catalog.js";
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

// ── Deep-link routes (PUBLIC — browsers, not the app) ─────────────────────────
// Served on arul.hsrutility.com, the host that ships in shares and ad creatives.
// All unauthenticated on purpose: assetlinks.json is fetched by Android's
// verifier, and /w/:id + /r/:id by whoever tapped the link. See routes/deeplink.ts.
app.get("/.well-known/assetlinks.json", handleAssetLinks);
app.get("/w/:id", handleWallpaperLink);
app.get("/r/:id", handleRingtoneLink);

// ── Auth routes ───────────────────────────────────────────────────────────────
app.post("/auth/login", handleLogin);
app.post("/auth/refresh", handleRefresh);
app.post("/auth/logout", handleLogout);

// ── Media routes (all gated) ──────────────────────────────────────────────────
app.post("/media/signed-url", handleSignedUrl);
app.post("/media/upload-url", handleUploadUrl);
app.post("/media/confirm-upload", handleConfirmUpload);

// ── Payment routes (PhonePe Autopay v2) ───────────────────────────────────────
app.post("/payments/initiate", handleInitiate);    // JWT — mandate: ₹2 PENNY_DROP / ₹199 TRANSACTION
app.post("/payments/webhook", handleWebhook);      // S2S callback (callback-auth verified)
app.post("/payments/status", handleStatus);        // JWT — reconcile live subscription state
app.post("/payments/cancel", handleCancel);        // JWT — revoke mandate (Manage Subscription)
app.post("/payments/abandon", handleAbandon);      // JWT — release a claimed setup after SDK cancel
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
    // "0 * * * *" — hourly: catalog rebuild + on-change canonical sweep
    // (autopay has its own trigger below — it must not share this invocation's
    // 15-minute wall clock with the rebuild)
    if (event.cron === "0 * * * *") {
      console.log("[cron] Running hourly catalog rebuild");
      ctx.waitUntil(
        buildCatalog(env, null).then(async (results) => {
          console.log("[cron] Catalog rebuild complete:", JSON.stringify(results));
          // Canonical-media sweep runs strictly AFTER a rebuild that actually
          // touched a scope — if any scope failed, its stale catalog pages may
          // still reference a just-unreferenced object, and deleting the bytes
          // then would break the live feed (backstop for abandoned CMS uploads
          // + lost delete/replace cleanups). And if every scope was skipped as
          // { skipped: "no_change" }, nothing was unreferenced this run, so
          // there's nothing new to reclaim — the daily cron below is the
          // backstop for everything else (this hourly sweep is purely an
          // on-change convenience, not the safety net).
          const anyScopeError = Object.values(results).some(
            (r) => r && typeof r === "object" && "error" in r,
          );
          if (anyScopeError) {
            console.warn("[cron] Skipping canonical sweep — a catalog scope failed to rebuild");
            return;
          }
          const anyScopeRebuilt = Object.values(results).some(
            (r) => r && typeof r === "object" && "pages" in r,
          );
          if (!anyScopeRebuilt) {
            console.log("[cron] Skipping canonical sweep — no scope changed this run");
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

    }

    // "*/15 * * * *" — autopay, in its OWN invocation every quarter hour. One
    // invocation is capped at ~600 PhonePe calls by the 15-minute cron wall
    // clock (Workers Paid; sequential calls at ~1 s each), so a due backlog
    // still drains by cadence as well as by run size. Autopay used to ride the
    // hourly trigger above, sharing that invocation with the catalog rebuild
    // (R2 + KV + Neon) — at 04:00Z on 2026-08-25 the two together blew the
    // then-50-subrequest cap mid-scan. Separate cron expressions get separate
    // invocations, so minute 0 now runs catalog and autopay side by side, each
    // with a full budget, and there is still exactly ONE autopay scan per tick.
    if (event.cron === "*/15 * * * *") {
      console.log("[cron] Running quarter-hour autopay scan");
      ctx.waitUntil(
        runAutopayNotify(env).catch((err: unknown) => {
          console.error("[cron] Autopay notify failed:", err);
        }),
      );
    }

    // "30 21 * * *" — daily off-peak backstop: unconditional sweeps for
    // everything the hourly on-change sweep and inline cleanups might miss.
    if (event.cron === "30 21 * * *") {
      console.log("[cron] Running daily canonical + submission sweeps");
      ctx.waitUntil(
        sweepCanonical(env).then((result) => {
          console.log("[cron] Daily canonical sweep complete:", JSON.stringify(result));
        }).catch((err: unknown) => {
          console.error("[cron] Daily canonical sweep failed:", err);
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

      // Publish the day's apply/set counts by bumping content_version. The
      // rebuild itself is left to the next hourly run 30 minutes later — it
      // already holds the build lock and the change-detection gate, so doing it
      // here would just be a second builder racing the first.
      ctx.waitUntil(
        refreshPopularityOrder(env).then((result) => {
          console.log("[cron] Popularity refresh:", JSON.stringify(result));
        }).catch((err: unknown) => {
          console.error("[cron] Popularity refresh failed:", err);
        }),
      );
    }
  },
};

export default worker;
