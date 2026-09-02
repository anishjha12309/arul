/**
 * Typed environment bindings for the Arul Worker.
 *
 * Bindings come from the runtime, secrets from `wrangler secret bulk` -> wrangler.toml carries the full list
 * A field declared non-optional here is NOT enforced at deploy -> an unset secret fails at first use, not at boot
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
  // Optional so tests and any older deployment still run -> an absent limiter reads as "allow" (lib/ratelimit.ts)
  /** /payments/initiate — keyed by user id */
  RL_PAYMENTS?: RateLimit;
  /** /auth/login + /auth/refresh — keyed by client IP */
  RL_AUTH?: RateLimit;
  /** /media/signed-url — keyed by user id */
  RL_MEDIA?: RateLimit;

  // ── Secrets (wrangler secret put) ────────────────────────────────────────
  /** HS256 signing secret — min 32 bytes of entropy */
  JWT_SECRET: string;
  /** The WEB client id, not the Android one -> it is what `aud` on a Google id token must equal */
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
   * LOCAL-DEV-ONLY override for the PhonePe PG base URL. Harness: .claude/skills/verify-payments/
   *
   * PhonePe's UAT sandbox never settles a redemption on demand -> it holds PENDING through its own retry cycle
   * So the COMPLETED and FAILED branches were unreachable without spending real money -> point this at a local stub
   * getPgBase IGNORES it whenever PHONEPE_ENV resolves to PRODUCTION -> setting it on the deployed Worker is inert
   * Never set from wrangler.toml or a secret -> only workers/.dev.vars, git-ignored and read only by `wrangler dev`
   */
  PHONEPE_BASE_URL_OVERRIDE?: string;

  /**
   * The SAFE internal routes only: /internal/build-catalog, /internal/sweep-submissions, /internal/sweep-canonical.
   *
   * hsr-cms holds this string to trigger rebuilds -> its blast radius must stay content -> it authorizes no money route
   */
  CATALOG_BUILD_SECRET: string;

  /**
   * Operator-only, for the routes that MOVE REAL MONEY: /internal/run-redemptions (debits ₹199), /internal/refund.
   *
   * CATALOG_BUILD_SECRET is distributed to hsr-cms -> one string must never authorize "rebuild" AND "charge everybody"
   * Never hand this to the CMS or any other service -> it fails closed when unset, so a 401 means the wrong secret
   */
  OPS_SECRET: string;

  /**
   * HMAC key for trial_tombstones.google_sub_hash (the delete-account trial guard).
   * A new key orphans every existing tombstone -> trial farming re-opens -> NEVER rotate
   */
  TRIAL_TOMBSTONE_SECRET: string;

  // ── PostHog capture — the ONLY server-side analytics sink (lib/posthog.ts) ──
  // GA4 and Meta server reporting were removed -> one conversion must have ONE data source -> never re-add them
  /**
   * PostHog project API key (phc_…) — write-only and already shipped in the APK, yet kept out of the repo.
   * Absent -> capture is skipped, never thrown -> analytics must not fail a payment (fail-open)
   */
  POSTHOG_API_KEY?: string;
  /**
   * PostHog ingestion host, defaulting to https://us.i.posthog.com when unset.
   * Must match the app's POSTHOG_HOST dart-define -> a split host splits the funnel -> set in wrangler.toml [vars]
   */
  POSTHOG_HOST?: string;

  /**
   * Comma-separated CORS allow-list for browser origins, e.g. "https://arul.hsrutility.com".
   *
   * The Flutter app is not a browser and hsr-cms arrives over a service binding -> CORS applies to neither
   * So this gates only a real browser client -> widening it never unblocks the app or the CMS
   */
  ALLOWED_ORIGINS: string;

  /**
   * Comma-separated SHA-256 fingerprints served in /.well-known/assetlinks.json — Android's App Link proof.
   *
   * The file is public by design -> NOT a secret -> set in wrangler.toml [vars]
   * Play re-signs every AAB with the APP SIGNING key -> an upload-key-only list fails on every Play install
   * It still verifies on a locally-built release APK -> list BOTH so sideloads work too
   * App Link failure is silent (the link just opens a browser) -> read the truth off the device, not the console
   * Absent -> the route 503s instead of serving an empty file -> a missing config shows up in a curl
   */
  ANDROID_CERT_SHA256?: string;
}
