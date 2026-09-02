/**
 * Arul API Worker entry point.
 *
 * Hono over itty-router -> middleware, typed contexts and error envelopes are built in -> hono.dev/docs
 * THREE cron triggers: hourly, quarter-hour (autopay only) and daily 21:30 UTC -> each detailed in scheduled() below
 * Every error response is { "error": { "code": string, "message": string } }
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
  handleRootLink,
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
// The Flutter app is not a browser -> CORS never applies to it -> ALLOWED_ORIGINS gates web callers only
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
// Served on arul.hsrutility.com, the host that ships in shares and ad creatives
// Android's verifier and whoever tapped the link fetch these -> auth would break both -> PUBLIC (routes/deeplink.ts)
app.get("/.well-known/assetlinks.json", handleAssetLinks);
app.get("/w/:id", handleWallpaperLink);
app.get("/r/:id", handleRingtoneLink);
// `/w/?lang=hi` is a language-only campaign link and the app's pathPrefix filter already matches it
// A 404 here -> the same URL opens the app for one person and an error page for the next -> redirect instead
// Ad ops paste both slash forms -> register both
app.get("/w/", handleWallpaperLink);
app.get("/w", handleWallpaperLink);
app.get("/r/", handleRingtoneLink);
app.get("/r", handleRingtoneLink);
// The bare link domain only (never the API host) — see handleRootLink.
app.get("/", handleRootLink);

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

// Authoring lives in the unified CMS worker (hsr-cms) -> this worker has no /admin -> see README
// hsr-cms reaches it through the ARUL_API service binding + /internal/build-catalog

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
    // "0 * * * *" -> catalog rebuild, then the canonical sweep only when a scope changed
    // Autopay has its OWN trigger below -> it must not share this invocation's wall clock with the rebuild
    if (event.cron === "0 * * * *") {
      console.log("[cron] Running hourly catalog rebuild");
      ctx.waitUntil(
        buildCatalog(env, null).then(async (results) => {
          console.log("[cron] Catalog rebuild complete:", JSON.stringify(results));
          // A failed scope leaves pages pointing at unreferenced objects -> deleting them breaks the feed -> skip the sweep
          // Every scope { skipped: "no_change" } -> nothing was unreferenced this run -> nothing to reclaim
          // Catches abandoned CMS uploads and lost delete/replace cleanups -> the daily cron is the real safety net
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

    // Autopay gets its OWN invocation -> sharing the hourly one blew the subrequest cap -> never fold it back in
    // The 15-minute cron wall clock caps one run at ~600 sequential PhonePe calls -> a backlog drains by cadence too
    // Minute 0 runs catalog and autopay side by side, each with a full budget, still ONE autopay scan per tick
    if (event.cron === "*/15 * * * *") {
      console.log("[cron] Running quarter-hour autopay scan");
      ctx.waitUntil(
        runAutopayNotify(env).catch((err: unknown) => {
          console.error("[cron] Autopay notify failed:", err);
        }),
      );
    }

    // "30 21 * * *" -> off-peak -> unconditional sweeps for what the on-change sweep and inline cleanups miss
    if (event.cron === "30 21 * * *") {
      console.log("[cron] Running daily canonical + submission sweeps");
      ctx.waitUntil(
        sweepCanonical(env).then((result) => {
          console.log("[cron] Daily canonical sweep complete:", JSON.stringify(result));
        }).catch((err: unknown) => {
          console.error("[cron] Daily canonical sweep failed:", err);
        }),
      );

      // Backstop for the inline delete-on-approve/reject -> reclaims orphaned R2 submissions, no-op when none
      ctx.waitUntil(
        sweepSubmissions(env).then((result) => {
          console.log("[cron] Submission sweep complete:", JSON.stringify(result));
        }).catch((err: unknown) => {
          console.error("[cron] Submission sweep failed:", err);
        }),
      );

      // Bumping content_version is what publishes the day's apply/set counts
      // The next hourly run already holds the build lock and the change gate -> rebuilding here would race it
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
