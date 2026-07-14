/**
 * Worker environment for the unified HSR CMS.
 *
 * Two of everything app-scoped (Hyperdrive + R2), one of everything
 * operator-scoped (admin credentials, R2 S3 token). Per-app values (bucket
 * names, CDN/API bases, catalog secrets) are looked up through src/registry.ts
 * so a route can never accidentally reach for "the other app's" binding.
 */

/**
 * URL prefix every CMS page lives under. The Worker is attached to the route
 * api.hsrutility.com/admin* (it took the path over from the Pakiza worker's
 * own CMS), so every route, link, form action, redirect and the session
 * cookie's Path carry this prefix. The ONLY non-admin surface is
 * POST /payments/webhook (src/payments-dispatch.ts).
 */
export const ADMIN_BASE = "/admin";

export interface Env {
  // ── App-scoped bindings (resolved ONLY via the registry) ──────────────────
  HYPERDRIVE_PAKIZA: Hyperdrive;
  HYPERDRIVE_ARUL: Hyperdrive;
  R2_PAKIZA: R2Bucket;
  R2_ARUL: R2Bucket;

  // ── Operator auth (single-operator model, one login for both apps) ────────
  ADMIN_USERNAME: string;
  /** PBKDF2-HMAC-SHA256 digest: "pbkdf2$<iters>$<saltB64>$<hashB64>" */
  ADMIN_PASSWORD_HASH: string;
  /** HS256 key for the hsr_cms session cookie */
  ADMIN_SESSION_SECRET: string;

  // ── R2 S3 API (ONE account-scoped token — covers both buckets; the bucket
  //    name in each presigned URL comes from the registry) ────────────────────
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  R2_ENDPOINT: string;

  // ── Per-app rebuild secrets (Authorization: Bearer … to the app Workers) ──
  ARUL_CATALOG_BUILD_SECRET: string;
  PAKIZA_CATALOG_BUILD_SECRET: string;

  // ── Service bindings to the app Workers (rebuild trigger). Plain fetch() to
  //    a sibling *.workers.dev host is blocked by Cloudflare (same-zone
  //    worker-to-worker), so rebuilds go through these; optional so local
  //    `wrangler dev` without the bindings falls back to fetch(). ─────────────
  ARUL_API?: Fetcher;
  PAKIZA_API?: Fetcher;
}
