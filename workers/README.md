# Arul Workers

Cloudflare Worker = API + crons. Neon via Hyperdrive · R2 `south-indian-wallpapers` behind
`https://arul-cdn.hsrutility.com` (presign via aws4fetch) · KV (jti denylist, webhook dedupe, PhonePe
OAuth cache) · PhonePe v2 Autopay on **PRODUCTION** credentials. Architecture, entitlement and the
catalog build: [docs/architecture.md](../docs/architecture.md) · crons:
[docs/cron.md](../docs/cron.md) · PhonePe: [docs/phonepe.md](../docs/phonepe.md) · caching:
[docs/caching.md](../docs/caching.md).

## Hosts

- **`https://arul-api.hsrutility.com`** — a `custom_domain` route, so `wrangler deploy` owns the hostname
  and its DNS record. **`arul.hsrutility.com`** is the second route: share and ad landings plus
  `assetlinks.json`, the only host browsers talk to ([docs/deep-links.md](../docs/deep-links.md)).
- **`arul-api.twilight-smoke-d495.workers.dev` must keep serving** (`workers_dev = true`): shipped
  builds call it. Declaring any `routes` entry defaults workers.dev to OFF — the custom domain stays
  healthy while that host answers error 1042 and every such install dies. Keep the line while any
  such install exists.

## Routes

| Method | Path | Auth | Contract |
|--------|------|------|----------|
| POST | /auth/login | — | Google idToken + nonce → access + rotating refresh JWTs; captures the referral code |
| POST | /auth/refresh · /auth/logout | — / Bearer | Rotate (old jti denylisted) · denylist the refresh jti |
| GET | /me | Bearer | Identity + subscription row + computed `premium` in ONE query |
| GET | /me/subscription · /me/submissions · /me/referrals | Bearer | Scoped to the verified sub; `/me/subscription` only for old builds |
| POST | /me/profile | Bearer | Display-name edit |
| DELETE | /me | Bearer | Revoke mandate(s) → trial tombstone → cascade → denylist |
| POST | /media/signed-url | Bearer | **Live premium check** → presigned R2 GET; kind ∈ {wallpaper, ringtone}; bumps the popularity counter |
| POST | /media/upload-url | Bearer | Presigned PUT under `user/<sub>/submissions/…` only |
| POST | /media/confirm-upload | Bearer | Record a submission — byte-QC'd against its KIND's role, ≤10 pending, upsert on `file_key` |
| POST | /payments/initiate · status · cancel · abandon | Bearer | Mandate lifecycle; 409 `setup_in_progress` ≠ `already_subscribed` |
| POST | /payments/webhook | SHA256(user:pass) | S2S callback, deduped on (event, orderId) |
| GET | /payments/callback | — | Post-mandate browser redirect |
| GET | /geo | — | `{country, region, lang}` from `request.cf` alone, `no-store`; `lang` only on `?v=2` while `GEO_LANG_ENABLED` is exactly `"true"` |
| POST | /push/device | — | Signed-out FCM registration; 2 KB cap; never writes `user_id` |
| POST | /me/device · /me/push-opened | Bearer | Signed-in registration (re-points the row) · campaign open |
| GET | /w/:id · /r/:id (and id-less) · / · /.well-known/assetlinks.json | — | Landing bounce pages and App Link proof ([docs/deferred-links.md](../docs/deferred-links.md)) |
| POST | /internal/build-catalog · sweep-submissions · sweep-canonical | CATALOG_BUILD_SECRET | Catalog and storage ops |
| POST | /internal/push/count · dispatch · test | PUSH_SECRET | Campaign push ([docs/push.md](../docs/push.md)) |
| POST | /internal/run-redemptions · refund | **OPS_SECRET** | Moves real money; fails closed when unset |

Errors: `{ "error": { "code", "message" } }` with 4xx/5xx. **Three secrets, three blast radii:**
`CATALOG_BUILD_SECRET` is handed to the CMS, so it must never also authorize "message every user"
(`PUSH_SECRET`) or "charge everybody" (`OPS_SECRET`). A 401 on one of those routes means the wrong
secret — never widen one.

Rate limiters (`RL_PAYMENTS`, `RL_AUTH` per identity, never IP, `RL_MEDIA`) are abuse dampeners, not
quotas: counters are per-location and eventually consistent. Limits sit far above real behaviour on
purpose — blocking someone who is trying to pay is the worst false positive in the app.

## Authoring — the unified CMS (NOT in this repo)

All authoring lives in the `hsr-cms` worker (`https://api.hsrutility.com/admin`, repo
`c:\Anish\Unified CMS`). It reaches this Worker through the **`ARUL_API` service binding** — a plain
`fetch()` to a sibling `*.workers.dev` host is blocked by Cloudflare. This Worker exposes no `/admin`.

The R2 CORS rule for browser uploads allows TWO origins — `https://api.hsrutility.com` (the CMS) and
`https://cdn.hsrutility.com`, no `arul-*` host. Write both back when editing it, or you drop one.

## Secrets

Set with `npx wrangler secret bulk <file.json>`, never a shell pipe (CLAUDE.md §4), with fresh values —
never another app's.

```
JWT_SECRET  GOOGLE_WEB_CLIENT_ID  ANDROID_CERT_SHA256(assetlinks fingerprints, comma-separated)
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_CDN_BASE_URL
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV(SANDBOX|PRODUCTION)  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  OPS_SECRET  PUSH_SECRET  TRIAL_TOMBSTONE_SECRET(set once, NEVER rotate)
FCM_SA_CLIENT_EMAIL  FCM_SA_PRIVATE_KEY  FIREBASE_PROJECT_ID  ALLOWED_ORIGINS  POSTHOG_API_KEY
```

The FCM pair comes from the Firebase service-account JSON, so the PEM arrives with literal `\n` —
`lib/fcm.ts` normalises exactly that. There is no purge credential and no `GA4_*`/`META_*` secret: `?v=`
replaced purging, and server-side conversion reporting must not return
([docs/analytics-events.md](../docs/analytics-events.md)).

## Dev / deploy

```bash
npm install
npm run dev      # wrangler dev — reads .dev.vars; its Hyperdrive string points at the Neon `debug` branch, never prod
npm run build && npm test
npx wrangler deploy   # deploy IS part of "done" — the deploy-worker skill
```

- **In `wrangler.toml`, a key's POSITION decides whether it deploys, and wrangler only warns.** A bare
  key under a `[table]` header is captured by that table (`workers_dev` under `[triggers]` once
  killed every installed build via error 1042); a key that belongs in `[vars]` without that header is
  DISCARDED — the state of `POSTHOG_HOST` and `ANDROID_CERT_SHA256`
  ([docs/known-issues.md](../docs/known-issues.md)). Read `npx wrangler deploy --dry-run`'s warnings.
- **Two `wrangler dev` instances on port 8787** — the second bind does not fail loudly, and the stale
  process serves old config as a phantom `502` or missing cron output. `netstat -ano | grep :8787` first.
- `wrangler kv key list --namespace-id <prod-id>` reads a **local** namespace and returns `[]` — add
  `--remote`.

**Prod inspection:** `tools/prod-query.mjs` (SELECT/WITH only, refuses stacked statements and write
keywords) and `tools/prod-sql.mjs` (writes need `--write`; an unqualified UPDATE/DELETE is refused even
then). Both read the connection string from `.dev.vars`, never the CLI, so it cannot leak into shell
history. `tools/prod-webhook.mjs` hardcodes `/payments/webhook`, refuses non-`DKS_` ids and cannot be
pointed at a money-moving route.
