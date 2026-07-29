# Provisioning — record of Arul's infrastructure (nothing is shared with the reference app)

**STATUS 2026-07-20: every Phase-0/1 item below is complete unless its box is unchecked.** The one
real open item is the custom domains (see ⚠ below). Originally a pre-Phase-1 checklist; kept as the
inventory of what exists and where.

Sharing Pakiza's bucket/KV/DB/JWT secret would let each app delete the other's media and
accept the other's tokens. Everything below is Arul-only. `[user]` = only you can do it.

## Cloudflare (account `ba8dd87179e2ffd378a50292ca8e69e0`, login admin@hsrutility.com)
- [x] R2 bucket `south-indian-wallpapers` — exists (created 2026-07-09, APAC, 429 objects / 1.75 GB
      incl. the `catalog/catalog.json` import manifest); public dev-url ON:
      `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev` (dev/testing ONLY — throttled)
- [x] KV namespace: `cd workers && npx wrangler kv namespace create KV` (+ `--preview`) → ids into wrangler.toml
- [x] Hyperdrive: `npx wrangler hyperdrive create arul-hyperdrive --connection-string="<NEON_URL>"`
      → id into wrangler.toml. **Query caching stays OFF.**
- [x] R2 S3 API token (Object Read & Write, this bucket only) → `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`
      secrets — presigning verified working in prod
- [x] R2 CORS rule, method PUT, header `content-type` (CMS browser uploads PUT the S3 endpoint
      cross-origin). Origin is `https://api.hsrutility.com` — the hsr-cms worker, NOT an arul-* host.

- [x] **API custom domain `arul-api.hsrutility.com`** — live 2026-07-29. Declared in
      `workers/wrangler.toml` as a `custom_domain` route, so `wrangler deploy` created the hostname
      AND its DNS record; nothing was clicked in the dashboard and no zone id was needed.
      `workers_dev = true` is kept ALONGSIDE it so
      `arul-api.twilight-smoke-d495.workers.dev` keeps serving installed builds — dropping that line
      is what would break them, so it waits for a released build that uses the custom domain.
      `env/dev.json` + `env/prod.json` already point at the custom domain.
      Note: a subdomain of a zone you already own costs **nothing** — no registrar fee, no
      Cloudflare per-hostname charge. There was never a cost reason to avoid these.

### ⚠ OPEN — the only unfinished infrastructure item
- [ ] [user] **Media CDN custom domain `arul-cdn.hsrutility.com` is NOT attached.** Media still
      serves from `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev`.
      **This is required before launch, not cosmetic.** Cloudflare rate-limits the `r2.dev` URL and
      documents it as development-only, and — decisively — **caching, WAF and access controls do not
      apply to `r2.dev` at all**; a bucket must sit behind a custom domain to be cacheable. Shipping
      media on `r2.dev` therefore breaks the edge-cached / zero-egress cost model this whole app is
      built on (CLAUDE.md §2). Ref: developers.cloudflare.com/r2/buckets/public-buckets/
      Attach it either way:
      · CLI: `npx wrangler r2 bucket domain add south-indian-wallpapers --domain arul-cdn.hsrutility.com --zone-id <hsrutility.com zone id>`
        (the zone id is on the Cloudflare dashboard's zone Overview page; it is the ONLY reason this
        step is not already automated here)
      · Dashboard: R2 → `south-indian-wallpapers` → Settings → Custom Domains → Connect Domain
      Then: add the catalog Cache Rule (below), set the `R2_CDN_BASE_URL` secret, update
      `env/dev.json` + `env/prod.json`, rebuild the app. **No catalog rebuild is needed** — catalog
      rows carry relative keys, never absolute URLs. Leave the R2 CORS origin alone: it is
      `https://api.hsrutility.com` (the CMS), which does not move.

- [ ] [user] **Catalog Cache Rule for the new CDN host** (Caching → Cache Rules), once the domain is
      attached. `.json` is NOT in Cloudflare's default cacheable-extension list, so without this every
      catalog file stays `DYNAMIC`:
      · Match: `http.host eq "arul-cdn.hsrutility.com" and starts_with(http.request.uri.path, "/catalog/")`
      · Action: *Eligible for cache*, Edge TTL = **"Use cache-control header if present, bypass cache if not"**
      · **No per-path exclusions.** The origin header alone decides, so anything the Worker marks
        `no-store` is bypassed automatically. A leftover `version.json` exclusion is exactly what kept
        Pakiza's pointer uncached (`DYNAMIC` ~240 ms vs `HIT` ~40 ms) for days.

## Neon
- [x] [user] New Neon project `arul` (separate from Pakiza's) → pooled connection string
- [x] Apply `db/schema/01→04` then `db/seed.sql` (neon-migration skill — psql is not installed).
      `04_ringtones.sql` added 2026-07-17 with the ringtones reversal.
- [x] Connection string into `workers/.dev.vars` as `DATABASE_URL` (git-ignored) + the Hyperdrive config above

## Google (new Cloud project — never reuse Pakiza's OAuth clients)
- [x] [user] Firebase project + Android app `com.hsrapps.arul` → `android/app/google-services.json` (in
      place since 2026-07-18; both env files set `FIREBASE_ENABLED: "true"`)
- [x] [user] OAuth clients: **Web** (→ `GOOGLE_WEB_CLIENT_ID`, also the Worker secret) + **Android**
      (package `com.hsrapps.arul` + debug/upload SHA-1s) — real ids in `env/prod.json`. After first Play
      upload: register BOTH Play app-signing and upload SHA-1/256 in the Android client + Firebase, or
      tester sign-in breaks.
- [ ] [user] Link Firebase ↔ Google Ads if running install campaigns

## Analytics
- [x] [user] PostHog: new project (US region) → `POSTHOG_KEY` (real key in env). Autocapture stays OFF.
- [x] [user] Meta app: `META_APP_ID`/`META_CLIENT_TOKEN` set (real app id + token) — empty defines = SDK disabled

## PhonePe
- [x] [user] Decide: same merchant as Pakiza (default — reuse `PHONEPE_*` credential values, order
      prefix `DKS_` keeps streams distinguishable) or a separate merchant onboarding
- [x] [user] Webhook registered + username/password in the PhonePe dashboard. Running on **PRODUCTION**
      credentials. The registered URL is `https://api.hsrutility.com/payments/webhook` (the hsr-cms
      dispatcher, which forwards `DKS_`-prefixed orders to arul-api) — **not** an `arul-*` host.

## Play / signing
- [x] [user] New upload keystore: `keytool -genkeypair -v -keystore C:\Users\anish\arul-upload.jks
      -alias arul -keyalg RSA -keysize 2048 -validity 10000` (CN=HSR Apps) + `android/key.properties`
- [x] [user] Play Console listing `com.hsrapps.arul`, Play App Signing ON — **1.0.0+20** AAB uploaded
      (not yet public)
- [x] [user] Privacy policy page live: `https://hsrapps.com/arul/privacy-policy/` — disclosing
      Google/Firebase + PostHog (+ Meta + advertiser-ID if used). Served to the app via `policy_urls`
      (`db/seed.sql` → `app_config`); confirmed present in the live `catalog/app_config.json`.

## Worker secrets (`cd workers && npx wrangler secret put <NAME>` — fresh values, never Pakiza's)
```
JWT_SECRET (32+ random bytes)      GOOGLE_WEB_CLIENT_ID
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET=south-indian-wallpapers
R2_CDN_BASE_URL   # currently the r2.dev origin, NOT arul-cdn.hsrutility.com — see the ⚠ open item
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  TRIAL_TOMBSTONE_SECRET (set once, NEVER rotate)  ALLOWED_ORIGINS
CF_ZONE_ID  CF_PURGE_TOKEN   # optional: instant version-pointer purge on publish
```
`ADMIN_USERNAME` / `ADMIN_PASSWORD_HASH` / `ADMIN_SESSION_SECRET` are **not** this worker's secrets — they
belong to the hsr-cms worker. Deleted here with the legacy `/admin` removal (2026-07-20); verified gone
from `wrangler secret list`.

## App env
- [x] Copy `env.example.json` → `env/dev.json` + `env/prod.json`, fill values (git-ignored) — both exist
      and are filled

## Existing bucket content — verified 2026-07-14 (wrangler + S3 listing + ffprobe samples)
`wallpapers/<category>/<hex>.{jpg|mp4}` — 6 categories (amman/ayyappan/murugan/perumal/sivan/temples),
211 static + 217 live, all size-cap-clean; sampled media conforms to every rule (videos 1024×1824
h264 no-audio faststart). `catalog/catalog.json` = content-prep manifest → the Phase-3 import source
(titles, categories, dims, ranks). The app never reads it; build-catalog writes its own
`catalog/<scope>/…` + `version.json` + `app_config.json` beside it.

*Historical:* the manifest import ran 2026-07-14, registering all 428 as DB rows before the hourly cron
could sweep unreferenced `wallpapers/` keys (port-map Phase 3). The live catalog has since grown via the
CMS — **~514 wallpapers, 0 ringtones (no ringtone content published yet), content_version 16** as of
2026-07-20. The sweep rule still binds: any `wallpapers/`/`ringtones/` object without a DB row is deleted.
