# Provisioning — create BEFORE Phase 1 (nothing is shared with the reference app)

Sharing Pakiza's bucket/KV/DB/JWT secret would let each app delete the other's media and
accept the other's tokens. Everything below is Arul-only. `[user]` = only you can do it.

## Cloudflare (account `ba8dd87179e2ffd378a50292ca8e69e0`, login admin@hsrutility.com)
- [x] R2 bucket `south-indian-wallpapers` — exists (created 2026-07-09, APAC, 429 objects / 1.75 GB
      incl. the `catalog/catalog.json` import manifest); public dev-url ON:
      `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev` (dev/testing ONLY — throttled)
- [ ] [user] R2 custom domain `arul-cdn.hsrutility.com` on the bucket (dashboard → bucket →
      Settings → Custom Domains). Do NOT ship the throttled `r2.dev` URL to prod.
- [ ] KV namespace: `cd workers && npx wrangler kv namespace create KV` (+ `--preview`) → ids into wrangler.toml
- [ ] Hyperdrive: `npx wrangler hyperdrive create arul-hyperdrive --connection-string="<NEON_URL>"`
      → id into wrangler.toml. **Query caching stays OFF.**
- [ ] R2 S3 API token (Object Read & Write, this bucket only) → `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` secrets
- [ ] [user] Worker custom domain `arul-api.hsrutility.com` (dashboard → worker → Settings → Domains)
      after first deploy
- [ ] R2 CORS rule allowing origin `https://arul-api.hsrutility.com`, method PUT, header
      `content-type` (CMS browser uploads PUT the S3 endpoint cross-origin)

## Neon
- [ ] [user] New Neon project `arul` (separate from Pakiza's) → pooled connection string
- [ ] Apply `db/schema/01→03` then `db/seed.sql` (neon-migration skill — psql is not installed)
- [ ] Connection string into `workers/.dev.vars` as `DATABASE_URL` (git-ignored) + the Hyperdrive config above

## Google (new Cloud project — never reuse Pakiza's OAuth clients)
- [ ] [user] Firebase project + Android app `com.hsrapps.arul` → download `android/app/google-services.json`
- [ ] [user] OAuth clients: **Web** (→ `GOOGLE_WEB_CLIENT_ID`, also the Worker secret) + **Android**
      (package `com.hsrapps.arul` + debug/upload SHA-1s). After first Play upload: register BOTH
      Play app-signing and upload SHA-1/256 in the Android client + Firebase, or tester sign-in breaks.
- [ ] [user] Link Firebase ↔ Google Ads if running install campaigns

## Analytics
- [ ] [user] PostHog: new project (US region) → `POSTHOG_KEY`. Autocapture stays OFF.
- [ ] [user] Meta app (optional at launch): `META_APP_ID`/`META_CLIENT_TOKEN` — empty defines = SDK disabled

## PhonePe
- [ ] [user] Decide: same merchant as Pakiza (default — reuse `PHONEPE_*` credential values, order
      prefix `DKS_` keeps streams distinguishable) or a separate merchant onboarding
- [ ] [user] Register webhook `https://arul-api.hsrutility.com/payments/webhook` + username/password
      in the PhonePe dashboard (prod)

## Play / signing
- [ ] [user] New upload keystore: `keytool -genkeypair -v -keystore C:\Users\anish\arul-upload.jks
      -alias arul -keyalg RSA -keysize 2048 -validity 10000` (CN=HSR Apps) + `android/key.properties`
- [ ] [user] Play Console listing `com.hsrapps.arul`, Play App Signing ON
- [ ] [user] Privacy policy page live (e.g. `https://hsrapps.com/arul/privacy-policy/`) disclosing
      Google/Firebase + PostHog (+ Meta + advertiser-ID if used) — also goes in `db/seed.sql` policy_urls

## Worker secrets (`cd workers && npx wrangler secret put <NAME>` — fresh values, never Pakiza's)
```
JWT_SECRET (32+ random bytes)      GOOGLE_WEB_CLIENT_ID
R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_ENDPOINT  R2_BUCKET=south-indian-wallpapers
R2_CDN_BASE_URL=https://arul-cdn.hsrutility.com
PHONEPE_MERCHANT_ID  PHONEPE_CLIENT_ID  PHONEPE_CLIENT_SECRET  PHONEPE_CLIENT_VERSION
PHONEPE_ENV  PHONEPE_WEBHOOK_USERNAME  PHONEPE_WEBHOOK_PASSWORD
CATALOG_BUILD_SECRET  TRIAL_TOMBSTONE_SECRET (set once, NEVER rotate)  ALLOWED_ORIGINS
ADMIN_USERNAME  ADMIN_PASSWORD_HASH  ADMIN_SESSION_SECRET
CF_ZONE_ID  CF_PURGE_TOKEN   # optional: instant version-pointer purge on publish
```

## App env
- [ ] Copy `env.example.json` → `env/dev.json` + `env/prod.json`, fill values (git-ignored)

## Existing bucket content — verified 2026-07-14 (wrangler + S3 listing + ffprobe samples)
`wallpapers/<category>/<hex>.{jpg|mp4}` — 6 categories (amman/ayyappan/murugan/perumal/sivan/temples),
211 static + 217 live, all size-cap-clean; sampled media conforms to every rule (videos 1024×1824
h264 no-audio faststart). `catalog/catalog.json` = content-prep manifest → the Phase-3 import source
(titles, categories, dims, ranks). The app never reads it; build-catalog writes its own
`catalog/wallpapers/…` + `version.json` beside it. Register all 428 as DB rows before the hourly
cron starts sweeping unreferenced `wallpapers/` keys (port-map Phase 3).
