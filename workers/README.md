# Arul Workers

Cloudflare Worker = whole backend: API + CMS + crons. Base `https://arul-api.hsrutility.com`.
Neon via Hyperdrive · R2 `south-indian-wallpapers` (presign via aws4fetch) · KV (jti denylist,
webhook dedupe, OAuth cache) · PhonePe v2 Autopay. `src/` arrives in port-map Phase 2 — copied
verbatim from `c:\Anish\Pakiza\workers\src` + the **ringtones strip** and brand deltas in docs/port-map.md.

## Routes
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | /auth/login | — | Google idToken → access(15m) + refresh(60d rotating) JWTs; captures referral code |
| POST | /auth/refresh · /auth/logout | —/Bearer | Rotate (old jti denylisted) · denylist refresh jti |
| POST | /media/signed-url | Bearer | **Live premium check** → presigned R2 GET (apply/share gate) |
| POST | /media/upload-url | Bearer | Presigned PUT, `user/<sub>/submissions/…` only |
| POST | /media/confirm-upload | Bearer | Record submission — kind = `wallpaper` only, HEAD-verified, ≤10 pending/user, upsert on unique file_key |
| POST | /payments/{initiate,status,cancel} | Bearer | Autopay mandate lifecycle (see PhonePe below) |
| POST | /payments/webhook | SHA256(user:pass) | S2S callback; idempotent via KV orderId dedupe |
| GET | /payments/callback | — | Post-mandate browser redirect |
| GET/POST | /me · /me/{subscription,submissions,referrals} · /me/profile | Bearer | Scoped to verified sub |
| DELETE | /me | Bearer | Revoke mandate → trial tombstone (HMAC, never-rotate secret) → cascade → denylist |
| POST | /internal/{build-catalog,sweep-submissions,sweep-canonical,run-redemptions,refund} | CATALOG_BUILD_SECRET | Ops |
| ALL | /admin/* | Session cookie `arul_admin` | CMS |

Errors: `{ "error": { "code", "message" } }` with 4xx/5xx.

## Admin CMS (/admin/*)
Server-rendered Hono JSX+HTMX, single operator (PBKDF2 hash + signed HttpOnly cookie). Media bytes
upload browser → R2 direct via presigned PUT. Every mutation bumps `content_version` in the row's
transaction, rebuilds the scope, purges the version pointer. Pages: dashboard · wallpapers ·
submissions (approve→copy to canonical key→promote; NEVER approve a dimension-violating video as-is)
· config. (No ringtones page — module stripped in the port.)

## Catalog outputs (build-catalog)
`catalog/wallpapers/all_{page}.json` (20/page; no per-tag pages; orphaned pages deleted each rebuild) ·
`catalog/app_config.json` (public subset) · `catalog/version.json` (`no-store` pointer).
App reads version.json → appends `?v=<version>`; pages stay edge-cacheable (max-age=60).

## Cron — ONE hourly trigger (`0 * * * *`)
1. build-catalog (no-op if version unchanged) → **sweep-canonical** only after a fully successful
   rebuild (deletes `wallpapers/…` objects no DB row references — why this bucket must never be shared).
2. sweep-submissions (reclaim orphaned `user/…/submissions/`; expire 30d-old pending rows).
3. autopay notify (24h before debit) + execute (notify → redeem at next_debit_at).

## PhonePe v2 Autopay — hard-won facts, do NOT re-derive (proven in the reference app)
1. **Mobile SDK setup token** = `POST /checkout/v2/sdk/order`, read top-level `token`. NOT the web
   `/checkout/v2/pay` redirectUrl token (causes on-device PR004/401).
2. **One trial per user:** `trial_end` NULL → PENNY_DROP (₹2, 1-day trial); NOT NULL →
   `authWorkflowType: TRANSACTION` with real ₹199 first debit (`amount: 19900`) → straight to
   active. `maxAmount: 19900`, `amountType: FIXED`.
3. **Cancel path:** documented `/checkout/v2/subscriptions/{id}/cancel` 401s — the WORKING path is
   `/subscriptions/v2/{id}/cancel` (try first; documented path kept as fallback).
4. Recurring: `POST /subscriptions/v2/notify` → `POST /subscriptions/v2/redeem`;
   status `/subscriptions/v2/{id}/status?details=true`.
5. Webhook: `Authorization: SHA256(username:password)`; deduped by orderId in KV (30d TTL).
   Order-id prefix here is `DKS_` (distinguishes Arul if the merchant is shared).
6. **NEVER fall back to a web token.** If `sdk/order` returns no top-level `token`, THROW. Scraping
   `?token=` out of `redirectUrl` yields a web-checkout token, and the SDK answers PR004
   "Unauthorized" on device while the Worker happily returns 200 — undebuggable from the server.
7. **`PHONEPE_ENV` is an exact string compare.** A trailing newline (e.g. `"PRODUCTION" | wrangler
   secret put`) silently routed prod creds to the SANDBOX host, whose reply is
   `401 {"code":"401"}` — indistinguishable from bad credentials. `isProduction()` now trims and
   THROWS on anything but `PRODUCTION`/`SANDBOX`; creds + merchant id are trimmed too. Set secrets
   with `wrangler secret bulk <json>`, never a shell pipe.
8. **Flipping `PHONEPE_ENV` does NOT invalidate the cached OAuth token** (KV `phonepe:oauth`). Delete
   that key after any env/credential change or the old token is served against the new host.
9. Symptom map: PR004/Unauthorized on device = bad `merchantId` or a web token (the Worker validates
   NEITHER — it only echoes them, so it still returns 200). `OAuth 401` in the tail = wrong host or a
   whitespace-polluted credential.

## Secrets (`npx wrangler secret bulk <file.json>`) — fresh values, NEVER reuse another app's
```
JWT_SECRET  GOOGLE_WEB_CLIENT_ID
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_CDN_BASE_URL
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV(SANDBOX|PRODUCTION)  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  TRIAL_TOMBSTONE_SECRET(set once, NEVER rotate)  ALLOWED_ORIGINS
ADMIN_USERNAME  ADMIN_PASSWORD_HASH(node scripts/hash-admin-password.mjs '<pw>')  ADMIN_SESSION_SECRET
CF_ZONE_ID  CF_PURGE_TOKEN   # optional: purge version pointer on publish
```
CMS one-time setup: set the three ADMIN_* secrets, then add an R2 CORS rule allowing origin
`https://arul-api.hsrutility.com` for PUT with header `content-type`.

## Dev / deploy
```bash
npm install
npm run dev      # wrangler dev — needs .dev.vars (incl DATABASE_URL) + Hyperdrive localConnectionString
npm run build && npm test
npx wrangler deploy   # deploy IS part of "done" (CF login admin@hsrutility.com; see deploy-worker skill)
```

## Security invariants
Access token carries only `sub`; entitlement ALWAYS live-read from Neon. All SQL parameterized and
scoped to the verified sub (no RLS in v1 — the Worker is the sole gate). Upload keys forced under
`user/<sub>/`; canonical media only writable via CMS/approval. Secrets live in the Worker only.
