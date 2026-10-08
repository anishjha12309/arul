import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./env.js";
import { handleLogin, handleRefresh, handleLogout } from "./routes/auth.js";
import { handleSignedUrl, handleUploadUrl, handleConfirmUpload } from "./routes/media.js";
import {
  handleAssetLinks,
  handleWallpaperLink,
  handleRingtoneLink,
  handleStatusLink,
  handleRootLink,
} from "./routes/deeplink.js";
import { handleGeo } from "./routes/geo.js";
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
  handleRegisterDevice,
  handleRegisterAnonDevice,
  handlePushOpened,
  handlePaywallView,
  handleCheckoutEvent,
} from "./routes/me.js";
import {
  handleBuildCatalog,
  handleSweepSubmissions,
  handleSweepCanonical,
  handleRunRedemptions,
  handleRefund,
  handlePushCount,
  handlePushDispatch,
  handlePushTest,
} from "./routes/internal.js";
import { buildCatalog, refreshPopularityOrder } from "./cron/build-catalog.js";
import { sweepSubmissions } from "./cron/sweep-submissions.js";
import { sweepCanonical } from "./cron/sweep-canonical.js";
import { runAutopayNotify } from "./cron/autopay-notify.js";
import { runPushDispatch, sweepPush } from "./cron/push-dispatch.js";
import { claimCronSlot, pruneCronRuns } from "./lib/cron-claim.js";

const app = new Hono<{ Bindings: Env }>();

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

// Android's verifier and whoever tapped the link fetch these -> auth would break both -> PUBLIC (routes/deeplink.ts)
app.get("/.well-known/assetlinks.json", handleAssetLinks);
app.get("/w/:id", handleWallpaperLink);
app.get("/r/:id", handleRingtoneLink);
app.get("/s/:id", handleStatusLink);
// Hono routes strictly -> a pasted `/w/<id>/?lang=ta` 404ed at every visitor without the app
app.get("/w/:id/", handleWallpaperLink);
app.get("/r/:id/", handleRingtoneLink);
app.get("/s/:id/", handleStatusLink);
// `/w/?lang=hi` is a language-only campaign link and the app's pathPrefix filter already matches it
// A 404 here -> the same URL opens the app for one person and an error page for the next -> redirect instead
// Ad ops paste both slash forms -> register both
app.get("/w/", handleWallpaperLink);
app.get("/w", handleWallpaperLink);
app.get("/r/", handleRingtoneLink);
app.get("/r", handleRingtoneLink);
app.get("/s/", handleStatusLink);
app.get("/s", handleStatusLink);
// The bare link domain only (never the API host) — see handleRootLink.
app.get("/", handleRootLink);

// Read once per fresh install from request.cf -> host-agnostic, so pre-rename workers.dev installs get it too
app.get("/geo", handleGeo);

app.post("/auth/login", handleLogin);
app.post("/auth/refresh", handleRefresh);
app.post("/auth/logout", handleLogout);

app.post("/media/signed-url", handleSignedUrl);
app.post("/media/upload-url", handleUploadUrl);
app.post("/media/confirm-upload", handleConfirmUpload);

app.post("/payments/initiate", handleInitiate);
app.post("/payments/webhook", handleWebhook);
app.post("/payments/status", handleStatus);
app.post("/payments/cancel", handleCancel);
app.post("/payments/abandon", handleAbandon);
app.get("/payments/callback", handleCallback);

app.get("/me", handleMe);
app.post("/me/profile", handleUpdateProfile);
app.delete("/me", handleDeleteAccount);
app.get("/me/subscription", handleMeSubscription);
app.get("/me/submissions", handleMeSubmissions);
app.get("/me/referrals", handleMeReferrals);
app.post("/me/device", handleRegisterDevice);
app.post("/me/push-opened", handlePushOpened);
app.post("/me/paywall-view", handlePaywallView);
app.post("/me/checkout-event", handleCheckoutEvent);
app.post("/push/device", handleRegisterAnonDevice); // PUBLIC — a signed-out phone; never writes user_id

app.post("/internal/build-catalog", handleBuildCatalog);
app.post("/internal/sweep-submissions", handleSweepSubmissions);
app.post("/internal/sweep-canonical", handleSweepCanonical);
app.post("/internal/run-redemptions", handleRunRedemptions);
app.post("/internal/refund", handleRefund);
app.post("/internal/push/count", handlePushCount);
app.post("/internal/push/dispatch", handlePushDispatch);
app.post("/internal/push/test", handlePushTest);

app.onError((err, c) => {
  console.error("[worker] Unhandled error:", err);
  return c.json({ error: { code: "server_error", message: "Internal server error" } }, 500);
});

app.notFound((c) => {
  return c.json(
    { error: { code: "not_found", message: `Route not found: ${c.req.method} ${c.req.path}` } },
    404,
  );
});

type WorkerType = {
  fetch: (request: Request, env: Env, ctx: ExecutionContext) => Promise<Response>;
  scheduled: (event: ScheduledController, env: Env, ctx: ExecutionContext) => Promise<void>;
};

const worker: WorkerType = {
  fetch: async (req, env, ctx) => app.fetch(req, env, ctx),

  async scheduled(event, env, ctx) {
    // A tick can arrive twice -> every trigger but the push minute (SKIP LOCKED already) runs once per slot
    if (!(await claimCronSlot(env, event.cron, event.scheduledTime))) return;

    if (event.cron === "0 * * * *") {
      console.log("[cron] Running hourly catalog rebuild");
      ctx.waitUntil(
        buildCatalog(env, null)
          .then(async (results) => {
            console.log("[cron] Catalog rebuild complete:", JSON.stringify(results));
            // A failed scope leaves pages pointing at unreferenced objects -> deleting them breaks the feed -> skip the sweep
            // Every scope { skipped: "no_change" } -> nothing was unreferenced this run -> nothing to reclaim
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
          })
          .catch((err: unknown) => {
            console.error("[cron] Catalog rebuild failed:", err);
          }),
      );
    }

    if (event.cron === "*/15 * * * *") {
      console.log("[cron] Running quarter-hour autopay scan");
      ctx.waitUntil(
        runAutopayNotify(env).catch((err: unknown) => {
          console.error("[cron] Autopay notify failed:", err);
        }),
      );
    }

    if (event.cron === "* * * * *") {
      ctx.waitUntil(
        runPushDispatch(env)
          .then((result) => {
            // The disabled state still gets ONE line an hour, so a dark switch leaves a breadcrumb
            // rather than looking identical to a cron that never fires.
            if (result.started + result.attempted > 0) {
              console.log("[cron] Push dispatch:", JSON.stringify(result));
            } else if (result.skipped && new Date().getUTCMinutes() === 0) {
              console.log(`[cron] Push dispatch idle — ${result.skipped}`);
            }
          })
          .catch((err: unknown) => {
            console.error("[cron] Push dispatch failed:", err);
          }),
      );
    }

    if (event.cron === "30 21 * * *") {
      console.log("[cron] Running daily canonical + submission sweeps");
      ctx.waitUntil(
        sweepCanonical(env)
          .then((result) => {
            console.log("[cron] Daily canonical sweep complete:", JSON.stringify(result));
          })
          .catch((err: unknown) => {
            console.error("[cron] Daily canonical sweep failed:", err);
          }),
      );

      ctx.waitUntil(
        sweepSubmissions(env)
          .then((result) => {
            console.log("[cron] Submission sweep complete:", JSON.stringify(result));
          })
          .catch((err: unknown) => {
            console.error("[cron] Submission sweep failed:", err);
          }),
      );

      ctx.waitUntil(
        sweepPush(env)
          .then((result) => {
            console.log("[cron] Push sweep complete:", JSON.stringify(result));
          })
          .catch((err: unknown) => {
            console.error("[cron] Push sweep failed:", err);
          }),
      );

      ctx.waitUntil(
        pruneCronRuns(env)
          .then((pruned) => {
            console.log(`[cron] Pruned ${pruned} cron_runs rows`);
          })
          .catch((err: unknown) => {
            console.error("[cron] cron_runs prune failed:", err);
          }),
      );

      // The next hourly run already holds the build lock and the change gate -> rebuilding here would race it
      ctx.waitUntil(
        refreshPopularityOrder(env)
          .then((result) => {
            console.log("[cron] Popularity refresh:", JSON.stringify(result));
          })
          .catch((err: unknown) => {
            console.error("[cron] Popularity refresh failed:", err);
          }),
      );
    }
  },
};

export default worker;
