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

  /** Shared secret for POST /internal/build-catalog and /internal/run-redemptions */
  CATALOG_BUILD_SECRET: string;

  /**
   * HMAC key for trial_tombstones.google_sub_hash (delete-account trial guard).
   * NEVER rotate — a new key orphans every tombstone and re-opens trial farming.
   */
  TRIAL_TOMBSTONE_SECRET: string;

  // ── CMS admin (single-operator login for /admin) ─────────────────────────
  /** CMS admin login username (not secret, but set via wrangler secret). */
  ADMIN_USERNAME: string;
  /**
   * CMS admin password digest — NEVER the plaintext.
   * Format: "pbkdf2$<iterations>$<saltB64>$<hashB64>".
   * Generate with: node workers/scripts/hash-admin-password.mjs '<password>'
   */
  ADMIN_PASSWORD_HASH: string;
  /** HS256 secret for signing the admin session cookie — separate from JWT_SECRET. */
  ADMIN_SESSION_SECRET: string;

  // ── Optional: instant-update cache purge (publish → evict edge copy) ──────
  /** Cloudflare zone id; if set with CF_PURGE_TOKEN, publish purges the version pointer. */
  CF_ZONE_ID?: string;
  /** Cloudflare API token with "Cache Purge" permission for the zone above. */
  CF_PURGE_TOKEN?: string;
  /**
   * Comma-separated CORS allow-list for browser-based origins.
   * e.g. "https://arul.hsrutility.com"
   * The Flutter native app is not browser-based so CORS doesn't apply there;
   * only browser clients (web tools, operator UIs) need this.
   */
  ALLOWED_ORIGINS: string;
}
