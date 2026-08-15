# Arul Workers

Cloudflare Worker = API + crons. Base **`https://arul-api.hsrutility.com`** — a `custom_domain` route
in `wrangler.toml`, so `wrangler deploy` owns both the hostname and its DNS record.
`arul-api.twilight-smoke-d495.workers.dev` still serves in parallel (`workers_dev = true`) because
pre-rename installed builds point at it; **keep that line while any such install exists** — declaring
any `routes` entry makes wrangler default workers.dev to false and would silently kill every one.

Neon via Hyperdrive · R2 `south-indian-wallpapers` behind `https://arul-cdn.hsrutility.com`
(presign via aws4fetch) · KV (jti denylist, webhook dedupe, OAuth cache) · PhonePe v2 Autopay on
**PRODUCTION** credentials.

Deep dives: crons + the cold-connection hazard → [docs/cron.md](../docs/cron.md) · PhonePe endpoints
and traps → [docs/phonepe.md](../docs/phonepe.md) · Cache Rules and headers →
[docs/caching.md](../docs/caching.md).

## Routes
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | /auth/login | — | Google idToken → access(60m) + refresh(60d rotating) JWTs; captures referral code |
| POST | /auth/refresh · /auth/logout | —/Bearer | Rotate (old jti denylisted) · denylist refresh jti |
| POST | /media/signed-url | Bearer | **Live premium check** → presigned R2 GET (apply/share gate); kind ∈ {wallpaper, ringtone}; one DB round-trip |
| POST | /media/upload-url | Bearer | Presigned PUT, `user/<sub>/submissions/…` only |
| POST | /media/confirm-upload | Bearer | Record submission — kind = `wallpaper` only, HEAD-verified, ≤10 pending/user, upsert on unique file_key |
| POST | /payments/{initiate,status,cancel,abandon} | Bearer | Autopay mandate lifecycle; initiate 409s `setup_in_progress` vs `already_subscribed` |
| POST | /payments/webhook | SHA256(user:pass) | S2S callback; idempotent via KV orderId dedupe |
| GET | /payments/callback | — | Post-mandate browser redirect |
| GET | /me | Bearer | Identity **+ the subscription row in one query** (LEFT JOIN) — one cold-start round-trip |
| GET/POST | /me/{subscription,submissions,referrals} · /me/profile | Bearer | Scoped to verified sub. `/me/subscription` is kept only for old builds |
| DELETE | /me | Bearer | Revoke mandate → trial tombstone (HMAC, never-rotate secret) → cascade → denylist |
| POST | /internal/{build-catalog,sweep-submissions,sweep-canonical} | CATALOG_BUILD_SECRET | Catalog + storage ops |
| POST | /internal/{run-redemptions,refund} | **OPS_SECRET** | Moves real money — a separate secret on purpose, and fails closed when OPS_SECRET is unset |

Errors: `{ "error": { "code", "message" } }` with 4xx/5xx.

Rate limiters (`RL_PAYMENTS` 15/min, `RL_AUTH` 20/min per identity, `RL_MEDIA` 60/min) are abuse
dampeners, not quotas — counters are per-location and eventually consistent. Limits sit far above real
behaviour on purpose: blocking someone who is trying to pay is the worst false positive in the app.

## Authoring — the unified CMS (NOT in this repo)
All authoring for Arul AND Pakiza lives in the standalone **`hsr-cms`** worker:
`https://api.hsrutility.com/admin` (Arul under `/admin/arul/…`), repo `c:\Anish\Unified CMS` →
github.com/anishjha12309/hsr-cms. It never touches this repo's code.

It reaches this worker through the **`ARUL_API` service binding** and
`POST /internal/build-catalog` (bearer `CATALOG_BUILD_SECRET`). A plain `fetch()` to a sibling
`*.workers.dev` host is blocked by Cloudflare — the service binding is required.

`ADMIN_USERNAME` / `ADMIN_PASSWORD_HASH` / `ADMIN_SESSION_SECRET` are not read here and have been
deleted from this worker. The R2 CORS rule for browser uploads allows TWO origins —
`https://api.hsrutility.com` (the CMS) and `https://cdn.hsrutility.com`, no `arul-*` host. Write both back or you drop one.

## Catalog outputs (build-catalog)
`catalog/wallpapers/all_{page}.json` + `catalog/ringtones/all_{page}.json` (200/page; no per-tag
pages; orphaned pages deleted each rebuild; a zero-row scope still writes a valid empty `all_1.json`,
so a 404 there means the scope FAILED to build, not that it is empty) · `catalog/app_config.json`
(public subset) · `catalog/version.json` (edge-cached pointer). Scope queries end in `id ASC`, so
ordering is deterministic. The app reads version.json, then appends `?v=<version>` to page URLs.

**The backend is never conditional on the front end**: both scopes build unconditionally — keep the
scope, `kind='ringtone'`, and the `ringtones/` sweep prefix regardless of what the app ships.

## Secrets (`npx wrangler secret bulk <file.json>` — fresh values, NEVER reuse another app's)
```
JWT_SECRET  GOOGLE_WEB_CLIENT_ID
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET  R2_CDN_BASE_URL
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV(SANDBOX|PRODUCTION)  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  TRIAL_TOMBSTONE_SECRET(set once, NEVER rotate)  ALLOWED_ORIGINS
OPS_SECRET(money-moving internal routes; unset = they refuse, which is the safe default)
GA4_API_SECRET(GA4 Admin → Data streams → Android stream → MP API secrets; unset = server-side
  purchase reporting silently skips — its pair GA4_FIREBASE_APP_ID is plain config in wrangler.toml [vars])
```
Use `secret bulk`, never a shell pipe: a trailing newline in `PHONEPE_ENV` once routed production
credentials to the sandbox host. `isProduction()` now trims and throws; every OTHER secret is still
compared untrimmed. `CF_ZONE_ID`/`CF_PURGE_TOKEN` are gone from `env.ts` and set nowhere — there is no purge step anywhere, hsr-cms included; `?v=` does that job.

## Dev / deploy
```bash
npm install
npm run dev      # wrangler dev — needs .dev.vars (DATABASE_URL + WRANGLER_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE)
npm run build && npm test
npx wrangler deploy   # deploy IS part of "done" (CF login admin@hsrutility.com; see deploy-worker skill)
```

**Prod inspection** — `tools/prod-query.mjs` (SELECT/WITH only, refuses stacked statements and write
keywords) and `tools/prod-sql.mjs` (writes need `--write`; an unqualified UPDATE/DELETE is refused
even then). Both read the connection string from `.dev.vars`, never the CLI, so it cannot leak into
shell history. `tools/prod-webhook.mjs` hardcodes `/payments/webhook`, refuses non-`DKS_` ids, and
cannot be pointed at a money-moving route.

Two traps that silently return the wrong answer rather than erroring:
- `wrangler kv key list --namespace-id <prod-id>` reads a **local** namespace and returns `[]` — add `--remote`.
- `wallpapers` / `ringtones` use **`is_published`**, not `published`.

## Security invariants
Access token carries only `sub` (plus a non-authoritative `prm` UI hint); entitlement is ALWAYS
live-read from Neon. All SQL parameterized and scoped to the verified sub — no RLS in v1, the Worker
is the sole gate. Upload keys forced under `user/<sub>/` with a `/submissions/` infix; canonical media
only writable via CMS/approval. Secrets live in the Worker only.
