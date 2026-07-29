# Provisioning — Arul's infrastructure inventory

What exists, where, and how each piece was created. Every item is complete as of 2026-07-29 unless
its box is unchecked.

**Nothing here is shared with Pakiza.** Sharing a bucket, KV, DB or JWT secret would let each app
delete the other's media and accept the other's tokens. `[user]` = only the account owner can do it.

## Cloudflare (account `ba8dd87179e2ffd378a50292ca8e69e0`, login admin@hsrutility.com)
- [x] R2 bucket `south-indian-wallpapers` (created 2026-07-09, APAC)
- [x] KV namespace — `cd workers && npx wrangler kv namespace create KV` (+ `--preview`) → ids in wrangler.toml
- [x] Hyperdrive — `npx wrangler hyperdrive create arul-hyperdrive --connection-string="<NEON_URL>"`
      → id in wrangler.toml. **Query caching stays OFF** (caused ~60 s staleness).
- [x] R2 S3 API token (Object Read & Write, this bucket only) → `R2_ACCESS_KEY_ID` /
      `R2_SECRET_ACCESS_KEY`; presigning verified in prod
- [x] R2 CORS rule, method PUT, header `content-type`, origin `https://api.hsrutility.com` — the
      hsr-cms worker doing browser uploads, NOT an `arul-*` host. It does not move.
- [x] **API custom domain `arul-api.hsrutility.com`** — declared in `workers/wrangler.toml` as a
      `custom_domain` route, so `wrangler deploy` created the hostname AND its DNS record; nothing was
      clicked in the dashboard and no zone id was needed. `workers_dev = true` is kept alongside it so
      `arul-api.twilight-smoke-d495.workers.dev` keeps serving installed builds.
- [x] **Media CDN custom domain `arul-cdn.hsrutility.com`** — attached to the BUCKET, not the Worker,
      so wrangler.toml cannot express it:
      `npx wrangler r2 bucket domain add south-indian-wallpapers --domain arul-cdn.hsrutility.com --zone-id <hsrutility.com zone id>`
      (zone id from the dashboard's zone Overview — the only reason this step is not automated).
      Required, not cosmetic: Cloudflare rate-limits `r2.dev` and **caching, WAF and access controls
      do not apply to it at all**.
- [x] Two zone Cache Rules (catalog JSON + media) — configuration and traps in [caching.md](caching.md)

A subdomain of a zone you already own costs **nothing** — no registrar fee, no Cloudflare
per-hostname charge. There was never a cost reason to avoid these.

## Neon
- [x] [user] Project `arul` (separate from Pakiza's) → pooled connection string
- [x] Apply `db/schema/01→04` then `db/seed.sql` (neon-migration skill — psql is not installed)
- [x] Connection string into `workers/.dev.vars` as `DATABASE_URL` (git-ignored) + the Hyperdrive config

## Google (new Cloud project — never reuse Pakiza's OAuth clients)
- [x] [user] Firebase project + Android app `com.hsrapps.arul` → `android/app/google-services.json`
      (git-ignored; both env files set `FIREBASE_ENABLED: "true"`)
- [x] [user] OAuth clients: **Web** (→ `GOOGLE_WEB_CLIENT_ID`, also the Worker secret) + **Android**
      (package `com.hsrapps.arul` + debug/upload SHA-1s). After a Play upload, register BOTH the Play
      app-signing and upload SHA-1/256 in the Android client AND Firebase, or tester sign-in breaks.
- [ ] [user] Link Firebase ↔ Google Ads if running install campaigns ([analytics-ops.md](analytics-ops.md))

## Analytics
- [x] [user] PostHog project (US region) → `POSTHOG_KEY`. Autocapture stays OFF.
- [x] [user] Meta app: `META_APP_ID` / `META_CLIENT_TOKEN` set — empty defines disable the SDK

## PhonePe
- [x] [user] Same merchant as Pakiza; order prefix `DKS_` keeps the streams distinguishable
- [x] [user] Webhook registered on **PRODUCTION** credentials. The registered URL is
      `https://api.hsrutility.com/payments/webhook` — the hsr-cms dispatcher, which forwards `DKS_`
      orders to arul-api. **Not** an `arul-*` host.

## Play / signing
- [x] [user] Upload keystore `C:\Users\anish\arul-upload.jks` (CN=HSR Apps) + `android/key.properties`
- [x] [user] Play Console listing `com.hsrapps.arul`, Play App Signing ON — **1.0.0+20** AAB uploaded,
      not yet public
- [x] [user] Privacy policy live at `https://hsrapps.com/arul/privacy-policy/`, served to the app via
      `app_config.policy_urls` (`db/seed.sql`) and confirmed in the live `catalog/app_config.json`

## App env
- [x] `env.example.json` → `env/dev.json` + `env/prod.json` (git-ignored), both filled and pointing at
      the custom domains

## Bucket content
`wallpapers/<category>/<uuid|hex>.{jpg|mp4}` across 6 categories (amman, ayyappan, murugan, perumal,
sivan, temples). **614 wallpapers, 0 ringtones, `content_version` 45** as of 2026-07-29. The original
428 came from the bucket's own `catalog/catalog.json` manifest on 2026-07-14; the app never reads that
file, and it sits outside the swept prefixes so it survives. Everything since arrived through the CMS
or `tools/content-import/`.

**The sweep rule binds forever:** any object under `wallpapers/` or `ringtones/` without a DB row
referencing it is deleted ([cron.md](cron.md)).

Worker secret names are listed in [../workers/README.md](../workers/README.md); set them with
`wrangler secret bulk`, never a shell pipe.
