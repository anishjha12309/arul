/**
 * Typed environment bindings for the Arul Worker.
 *
 * Bindings are injected by the Cloudflare runtime; secrets are set via
 * `wrangler secret put <NAME>`.  See wrangler.toml for the full list.
 */
export interface Env {
  // ── Cloudflare bindings ──────────────────────────────────────────────────
  /** Workers KV namespace for refresh-token jti denylist + idempotency marks */
  KV: KVNamespace;
  /** Hyperdrive binding that provides a Postgres connection string to Neon */
  HYPERDRIVE: Hyperdrive;
  /** R2 bucket binding for catalog JSON writes (build-catalog cron) */
  R2: R2Bucket;

  // ── Rate limiters (see wrangler.toml [[ratelimits]]) ─────────────────────
  // Optional so tests and any older deployment without the bindings still run —
  // callers treat an absent limiter as "allow" (see lib/ratelimit.ts).
  /** /payments/initiate — keyed by user id */
  RL_PAYMENTS?: RateLimit;
  /** /auth/login + /auth/refresh — keyed by client IP */
  RL_AUTH?: RateLimit;
  /** /media/signed-url — keyed by user id */
  RL_MEDIA?: RateLimit;

  // ── Secrets (wrangler secret put) ────────────────────────────────────────
  /** HS256 signing secret — min 32 bytes of entropy */
  JWT_SECRET: string;
  /** Google OAuth2 Web Client ID used to verify the `aud` claim */
  GOOGLE_WEB_CLIENT_ID: string;

  // R2 S3-compatible credentials for presigning
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  /** e.g. https://<account-id>.r2.cloudflarestorage.com */
  R2_ENDPOINT: string;
  /** R2 bucket name, e.g. "south-indian-wallpapers" */
  R2_BUCKET: string;
  /** Public CDN base URL, e.g. https://cdn.hsrutility.com */
  R2_CDN_BASE_URL: string;

  // ── PhonePe v2 OAuth credentials (Standard Checkout / Autopay) ───────────
  /** PhonePe merchant ID (unchanged from v1) */
  PHONEPE_MERCHANT_ID: string;
  /** OAuth client_id provided by PhonePe during onboarding */
  PHONEPE_CLIENT_ID: string;
  /** OAuth client_secret provided by PhonePe during onboarding */
  PHONEPE_CLIENT_SECRET: string;
  /** OAuth client_version provided by PhonePe during onboarding */
  PHONEPE_CLIENT_VERSION: string;
  /** Webhook username configured in the PhonePe merchant dashboard */
  PHONEPE_WEBHOOK_USERNAME: string;
  /** Webhook password configured in the PhonePe merchant dashboard */
  PHONEPE_WEBHOOK_PASSWORD: string;
  /** "SANDBOX" | "PRODUCTION" */
  PHONEPE_ENV: string;

  /**
   * LOCAL-DEV-ONLY override for the PhonePe PG base URL.
   *
   * WHY: the autopay billing path (notify → execute → the ₹199 debit and the
   * state transition that follows) can only be exercised end-to-end if a
   * redemption reaches a TERMINAL state. PhonePe's UAT sandbox will not settle
   * a redemption on demand — it holds it PENDING through its own retry cycle —
   * so the COMPLETED and FAILED branches were, before this, unreachable
   * without spending real money on the live gateway. Pointing this at a local
   * stub makes both branches testable for free.
   *
   * IGNORED whenever PHONEPE_ENV resolves to PRODUCTION (see getPgBase), so
   * setting it on the deployed Worker can never redirect real money. It is
   * also never set by wrangler.toml or any secret — only by workers/.dev.vars,
   * which is git-ignored and loaded solely by `wrangler dev`.
   *
   * See .claude/skills/verify-payments/ for the full harness.
   */
  PHONEPE_BASE_URL_OVERRIDE?: string;

  /**
   * Shared secret for the SAFE internal routes: /internal/build-catalog,
   * /internal/sweep-submissions, /internal/sweep-canonical.
   *
   * The CMS worker holds this one purely to trigger rebuilds, so its blast
   * radius must stay limited to content. It deliberately does NOT authorize
   * anything that moves money — see OPS_SECRET.
   */
  CATALOG_BUILD_SECRET: string;

  /**
   * Operator-only secret for the routes that MOVE REAL MONEY:
   * /internal/run-redemptions (can debit ₹199 from live subscribers) and
   * /internal/refund.
   *
   * Kept separate from CATALOG_BUILD_SECRET on purpose: that secret is
   * distributed to the CMS worker for rebuild triggers, and a single string
   * must never authorize both "rebuild the catalog" and "charge everybody".
   * Never give this to the CMS or any other service.
   */
  OPS_SECRET: string;

  /**
   * HMAC key for trial_tombstones.google_sub_hash (delete-account trial guard).
   * NEVER rotate — a new key orphans every tombstone and re-opens trial farming.
   */
  TRIAL_TOMBSTONE_SECRET: string;

  // ── GA4 Measurement Protocol (server-side `purchase` — lib/ga4.ts) ───────
  /**
   * Firebase App ID of the Android app stream (google-services.json
   * `mobilesdk_app_id`). Ships inside every APK, so NOT a secret — set in
   * wrangler.toml [vars]. Optional: absent → server-side purchase reporting is
   * skipped (fail-open), which is also how tests run.
   */
  GA4_FIREBASE_APP_ID?: string;
  /**
   * Measurement Protocol api_secret — GA4 Admin → Data streams → <Android
   * stream> → Measurement Protocol API secrets. A real secret (grants event
   * write into the GA4 property): wrangler secret bulk, never [vars].
   */
  GA4_API_SECRET?: string;

  // ── Meta Conversions API (server-side first-conversion `Subscribe` —
  //    lib/meta.ts) ──────────────────────────────────────────────────────────
  /**
   * Events Manager dataset id linked to the Facebook app (Events Manager →
   * the app's data source → Settings). Not secret (visible in EM URLs) but
   * set via `wrangler secret bulk` alongside the token so neither lives in
   * the repo. Optional: absent → Meta reporting is skipped (fail-open).
   */
  META_DATASET_ID?: string;
  /**
   * Conversions API access token — Events Manager → dataset → Settings →
   * Conversions API → Generate access token. A REAL secret (grants event
   * write into the dataset): wrangler secret bulk, never [vars].
   */
  META_CAPI_ACCESS_TOKEN?: string;

  // ── PostHog capture (server-side first-conversion `subscription_active` —
  //    lib/posthog.ts) ───────────────────────────────────────────────────────
  /**
   * PostHog project API key (phc_…). Write-only and shipped inside the APK,
   * but kept out of the repo: wrangler secret bulk. Optional: absent →
   * PostHog reporting is skipped (fail-open).
   */
  POSTHOG_API_KEY?: string;
  /**
   * PostHog ingestion host. Defaults to https://us.i.posthog.com (the app's
   * POSTHOG_HOST) when unset — set in wrangler.toml [vars], not a secret.
   */
  POSTHOG_HOST?: string;

  /**
   * Comma-separated CORS allow-list for browser-based origins.
   * e.g. "https://arul.hsrutility.com"
   * The Flutter native app is not browser-based so CORS doesn't apply there.
   * Nor does the CMS: hsr-cms reaches this worker over the ARUL_API service
   * binding, which never goes through CORS. So this only matters if a real
   * browser client is ever pointed at this API.
   */
  ALLOWED_ORIGINS: string;

  /**
   * Comma-separated SHA-256 certificate fingerprints served in
   * /.well-known/assetlinks.json, which is what lets Android verify the App Link
   * on arul.hsrutility.com and open `/w/<id>` in the app instead of a browser.
   *
   * NOT a secret — the file is public by design; set in wrangler.toml [vars].
   *
   * Must include the **Play App Signing** certificate (Play Console → Setup →
   * App integrity → App signing key certificate), NOT just the upload key. Play
   * re-signs every AAB with the app signing key, so an upload-key-only file
   * verifies fine on a locally-built release APK and fails on every install that
   * actually came from Play — the failure mode is silent (links just open the
   * browser). List both so sideloaded release builds verify too.
   *
   * Absent → the route 503s rather than serving an empty file, so a missing
   * config is visible in a curl instead of looking like a working, unverified app.
   */
  ANDROID_CERT_SHA256?: string;
}
