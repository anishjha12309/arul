# Arul Workers

Cloudflare Worker = API + crons. Base **`https://arul-api.hsrutility.com`** (custom domain, live
2026-07-29 — declared as a `custom_domain` route in wrangler.toml, so `wrangler deploy` owns both the
hostname and its DNS record). `arul-api.twilight-smoke-d495.workers.dev` still serves in parallel
(`workers_dev = true`) because installed builds point at it; do not drop that until a release using
the custom domain has rolled out. **Media is still on the r2.dev origin** — see docs/provisioning.md
for the one remaining step (`arul-cdn.hsrutility.com`), which is required before launch.
**Authoring is NOT here** — the unified CMS is the separate `hsr-cms` worker/repo (see below).
Neon via Hyperdrive · R2 `south-indian-wallpapers` (presign via aws4fetch) · KV (jti denylist,
webhook dedupe, OAuth cache) · PhonePe v2 Autopay (**PRODUCTION** credentials). `src/` was ported
from `c:\Anish\Pakiza\workers\src` + the brand deltas in docs/port-map.md. (The original
**ringtones strip** was REVERSED 2026-07-17 — ringtones are back: scope `ringtones`, kind `ringtone`,
R2 `ringtones/` prefix. See port-map.md.)

## Routes
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | /auth/login | — | Google idToken → access(60m) + refresh(60d rotating) JWTs; captures referral code |
| POST | /auth/refresh · /auth/logout | —/Bearer | Rotate (old jti denylisted) · denylist refresh jti |
| POST | /media/signed-url | Bearer | **Live premium check** → presigned R2 GET (apply/share gate); kind ∈ {wallpaper, ringtone} |
| POST | /media/upload-url | Bearer | Presigned PUT, `user/<sub>/submissions/…` only |
| POST | /media/confirm-upload | Bearer | Record submission — kind = `wallpaper` only, HEAD-verified, ≤10 pending/user, upsert on unique file_key |
| POST | /payments/{initiate,status,cancel} | Bearer | Autopay mandate lifecycle (see PhonePe below) |
| POST | /payments/webhook | SHA256(user:pass) | S2S callback; idempotent via KV orderId dedupe |
| GET | /payments/callback | — | Post-mandate browser redirect |
| GET/POST | /me · /me/{subscription,submissions,referrals} · /me/profile | Bearer | Scoped to verified sub |
| DELETE | /me | Bearer | Revoke mandate → trial tombstone (HMAC, never-rotate secret) → cascade → denylist |
| POST | /internal/{build-catalog,sweep-submissions,sweep-canonical,run-redemptions,refund} | CATALOG_BUILD_SECRET | Ops |

Errors: `{ "error": { "code", "message" } }` with 4xx/5xx.

## Authoring — the unified CMS (NOT in this repo)
The legacy per-app `/admin` was removed on 2026-07-20. All authoring for Arul AND Pakiza now lives in
the standalone **`hsr-cms`** worker: `https://api.hsrutility.com/admin` (Arul pages under
`/admin/arul/…`), repo `c:\Anish\Unified CMS` → github.com/anishjha12309/hsr-cms.

It never touches this repo's code. It reaches this worker through the **`ARUL_API` service binding**
and `POST /internal/build-catalog` (bearer `CATALOG_BUILD_SECRET`). A plain `fetch()` to a sibling
`*.workers.dev` host is blocked by Cloudflare — the service binding is required.

The `ADMIN_USERNAME` / `ADMIN_PASSWORD_HASH` / `ADMIN_SESSION_SECRET` secrets are no longer read by
this worker (they now live on `hsr-cms`) and have already been deleted from it — `npx wrangler
secret list` no longer returns them.

## Catalog outputs (build-catalog)
`catalog/wallpapers/all_{page}.json` + `catalog/ringtones/all_{page}.json` (20/page; no per-tag pages;
orphaned pages deleted each rebuild; a zero-row scope still writes a valid empty all_1.json) ·
`catalog/app_config.json` (public subset) · `catalog/version.json` (edge-cached pointer:
`public, max-age=30, stale-while-revalidate=300` — NOT no-store; staleness stays bounded at 30 s).
App reads version.json → appends `?v=<version>`; pages stay edge-cacheable (max-age=60).
NOTE: media currently serves from the r2.dev origin (custom domain unattached), so no zone Cache
Rule applies yet. When `arul-cdn.hsrutility.com` lands, `.json` is not in Cloudflare's default
cacheable-extension list — add a Cache Rule matching the host + `/catalog/` prefix with Edge TTL
"Use cache-control header if present, bypass cache if not", and NO per-path exclusions (the origin
header alone decides; a `version.json` exclusion is exactly the stale trap Pakiza had to remove).

## Cron — TWO triggers (`wrangler.toml [triggers]`)

**Hourly `0 * * * *`** — two independent `waitUntil`s; neither can abort the other:
1. **build-catalog** — no-op if `content_version` is unchanged, so most hours only rewrite
   `app_config.json`. → **sweep-canonical**, but *only* after a rebuild that both fully succeeded
   and actually touched a scope (deletes `wallpapers/…` + `ringtones/…` objects no DB row
   references — full_key, audio_key AND cover_key all count as references — why this bucket must
   never be shared). On-change convenience, not the safety net.
2. **autopay notify + execute** — the renewal path. Pass A notifies 24 h before each debit; Pass B
   redeems at `next_debit_at`. Short-circuits on a KV `autopay:next_work_at` marker so an idle hour
   costs one KV read, not a DB wake.

**Daily `30 21 * * *`** (21:30 UTC = **03:00 IST**, off-peak) — the unconditional backstop for
whatever the on-change hourly sweep missed:
3. **sweep-canonical** — unconditional this time.
4. **sweep-submissions** — reclaim orphaned `user/…/submissions/` R2 objects and expire 30-day-old
   pending rows. "Expire" is a status flip to `rejected` with a reason, **not** a delete.

**Sweep failsafe — do not weaken.** When the DB reports **zero** referenced keys for a prefix,
sweep-canonical ABORTS that prefix rather than treating "no references" as "delete everything". A
sweep once wiped live media in the reference app; this is the guard.

**Cold-connection gotcha — the crons' one real hazard.** This Worker idles for hours (browse never
touches the DB), so Neon suspends and Hyperdrive's pooled connection goes stale. The first query of
a cron run then lands on a severed socket. postgres.js defaults `connect_timeout` to **30 s** —
longer than a scheduled invocation can afford — so the run hangs for the full budget and is killed
by the runtime, taking the rebuild AND the renewal scan with it (observed in the reference app:
killed the hourly cron for 3 h before anyone noticed, because a dead cron logs nothing).

Three defences, all load-bearing — don't remove one thinking the others cover it:
- `connect_timeout: 5` in `lib/db.ts` — fail fast instead of hanging.
- **Retry the first query once** on a fresh connection: `build-catalog` on its `app_config` read,
  `autopay-notify` on a `SELECT 1` before its passes. postgres.js reconnects transparently, so the
  second attempt succeeds.
- `await sql.end().catch(() => {})` — tearing down an already-severed socket can itself reject, and
  inside a `finally` that rejection **replaces the return value**, turning a fully successful
  rebuild into a failed promise.

Liveness signal: `catalog/app_config.json` is rewritten every successful run, so its
`Last-Modified` is what proves the cron is alive — `version.json`'s `built_at` only moves when
content actually changed. Cache-bust when checking (`?cb=<random>`); `REVALIDATED` can serve a
stale `Last-Modified`.

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
10. **The OAuth token endpoint is `/v1/oauth/token` and that is CORRECT on the v2 flow — do not
    "upgrade" it to v2.** Verified against PhonePe's own Authorization reference 2026-07-29:
    sandbox `https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token`, production
    `https://api.phonepe.com/apis/identity-manager/v1/oauth/token`. PhonePe's "v2" refers to the
    PRODUCT/API version and to the credential set, not to the token endpoint: v2 onboarding gives
    you v2 `client_id`/`client_secret`/`client_version`, which you POST to that v1 endpoint and
    which return a token you send as `Authorization: O-Bearer <token>`. This worker is fully on v2
    where it counts — `/checkout/v2/sdk/order`, `/subscriptions/v2/{notify,redeem,cancel,status}`,
    and the `O-Bearer` header. There is no v2 token endpoint to move to.

## Secrets (`npx wrangler secret bulk <file.json>`) — fresh values, NEVER reuse another app's
```
JWT_SECRET  GOOGLE_WEB_CLIENT_ID
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_CDN_BASE_URL
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV(SANDBOX|PRODUCTION)  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  TRIAL_TOMBSTONE_SECRET(set once, NEVER rotate)  ALLOWED_ORIGINS
```
`CF_ZONE_ID` / `CF_PURGE_TOKEN` used to live here for purge-on-publish. That path moved to
`hsr-cms` on 2026-07-20; they are no longer read, no longer declared in `env.ts`, and were never
set on this worker.
No ADMIN_* secrets here any more — they belong to the `hsr-cms` worker. The R2 CORS rule for browser
uploads must allow origin `https://api.hsrutility.com` (the CMS), not this worker.

## Dev / deploy
```bash
npm install
npm run dev      # wrangler dev — needs .dev.vars (incl DATABASE_URL) + Hyperdrive localConnectionString
npm run build && npm test
npx wrangler deploy   # deploy IS part of "done" (CF login admin@hsrutility.com; see deploy-worker skill)
```

**Prod inspection** — `tools/prod-query.mjs` (SELECT/WITH only, refuses stacked statements and
write keywords) and `tools/prod-sql.mjs` (writes need `--write`; an unqualified UPDATE/DELETE is
refused even then). Both read the connection string from `.dev.vars`, never the CLI, so it cannot
leak into shell history. `tools/prod-webhook.mjs` hardcodes `/payments/webhook`, refuses non-`DKS_`
ids, and cannot be pointed at a money-moving route.

Two traps that silently return the wrong answer rather than erroring:
- `wrangler kv key list --namespace-id <prod-id>` reads a **local** namespace and returns `[]`.
  Add `--remote`.
- `wallpapers` / `ringtones` use **`is_published`**, not `published`.

## Security invariants
Access token carries only `sub`; entitlement ALWAYS live-read from Neon. All SQL parameterized and
scoped to the verified sub (no RLS in v1 — the Worker is the sole gate). Upload keys forced under
`user/<sub>/`; canonical media only writable via CMS/approval. Secrets live in the Worker only.
