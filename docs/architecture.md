# Backend Architecture

Browse = CDN-only ($0 egress). Writes = Workers → Neon. Neon holds per-user state only; the app never touches it.
Base: `https://arul-api.twilight-smoke-d495.workers.dev` · CDN: `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev`
(R2 `south-indian-wallpapers`). ⚠ **OPEN:** the custom domains `arul-api`/`arul-cdn.hsrutility.com` are NOT
attached — these workers.dev/r2.dev origins are the deliberate interim state, to migrate to unified CDN domains.
Wallpapers **and ringtones**: the original ringtone strip was REVERSED 2026-07-17 (port-map).

**Routes:** auth.ts · media.ts (gated signed-url + submissions) · payments.ts (PhonePe v2 Autopay) · me.ts · internal.ts
**Cron (single hourly `0 * * * *`):** build-catalog → sweep-canonical (only after a fully successful rebuild) ∥ sweep-submissions ∥ autopay notify/execute
**Libs:** db.ts (Hyperdrive) · r2.ts (presign/copy) · jwt.ts · google.ts (idToken) · entitlement.ts (isPremium live read) · phonepe.ts

## API
JSON; errors `{error:{code,message}}`. Gated routes: `Authorization: Bearer <accessJWT>`.

**Auth** (identity-only JWT; entitlement never in token): POST /auth/{login,refresh,logout}
**Media** (premium-gated): POST /media/{signed-url,upload-url,confirm-upload}
**Payments:** POST /payments/{initiate,webhook,status,cancel} · GET /payments/callback (post-mandate redirect)
**Me** (scoped to sub): GET /me · /me/{subscription,submissions,referrals} · POST /me/profile · DELETE /me
**Internal** (CATALOG_BUILD_SECRET): POST /internal/{build-catalog,sweep-submissions,sweep-canonical,run-redemptions,refund}

## Entitlement (live read from Neon, never from JWT)
`isPremium = (status ∈ {trialing,active,cancelled} ∧ current_period_end > now()) ∨ users.reward_premium_until > now()`.
Cancelled keeps access until period end. Live read → purchase/refund apply instantly. No test bypass.

**One trial per user:** `subscriptions.trial_end` is the consumed-marker (written once, kept forever).
NULL → PENNY_DROP setup + trial; NOT NULL → TRANSACTION setup with real ₹199 first debit → straight to `active`.
Delete-account writes an HMAC tombstone so re-signup pre-seeds a consumed trial (no trial farming).

## Uploads (submissions)
upload-url presigns PUT to `user/<sub>/submissions/…` only. confirm-upload: kind = `wallpaper` (only),
HEAD-verifies the object, max 10 pending/user, upserts on unique file_key (idempotent retries).
Orphans reclaimed by sweep-submissions; pending rows expire after 30d.

## Catalog generation
Source: `app_config.content_version` (Neon). Trigger: CMS mutation, `/internal/build-catalog`, or hourly
cron (no-op if version unchanged). Output per scope (`wallpapers`, `ringtones`): `catalog/<scope>/all_{page}.json`
— ONE page set each, no per-category files — plus the shared `catalog/version.json` + `catalog/app_config.json`.
A zero-row scope still writes a valid empty `all_1.json` (ringtones today: no content published yet). Every item
carries `category`, and the app's **category** chips filter client-side (no All/New tabs, never a static/live
filter). Orphaned page files deleted each rebuild. Cache: version.json = no-store; pages = max-age=60 +
`?v=<version>` busting. Exposed keys are public: wallpaper full_key, ringtone audio_key + cover_key.
(`catalog/catalog.json` in the bucket is the one-time import manifest, not read by the app.)

CMS: **separate worker + repo** (`hsr-cms`, `c:\Anish\Unified CMS`) serving Arul + Pakiza from one
login at `api.hsrutility.com/admin`. Server-rendered Hono JSX+HTMX, single operator (PBKDF2). Mutation
= bytes + row + version bump + rebuild + purge (atomic). Scopes: wallpapers, ringtones, app_config,
submissions. It calls this worker via the `ARUL_API` service binding → `/internal/build-catalog`;
this worker exposes no `/admin` of its own (legacy removed 2026-07-20).

## Schema (Neon) — detail in docs/data-model.md, DDL in db/schema/
users · subscriptions · wallpapers · ringtones · content_submissions · referrals · trial_tombstones ·
app_config (singleton). No RLS — the Worker scopes every parameterized query to the verified sub.

## Security
JWT HS256: access 15m, refresh 60d rotating (jti denylisted in KV). idToken verified vs Google JWKS.
PhonePe v2 OAuth (O-Bearer); webhook `Authorization: SHA256(user:pass)`, deduped by orderId in KV.
Secrets live in the Worker only — the app holds none.
