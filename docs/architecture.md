# Backend Architecture

Browse = CDN-only ($0 egress). Writes = Workers → Neon. Neon holds per-user state only; the app never
touches it.

API `https://arul-api.hsrutility.com` · CDN `https://arul-cdn.hsrutility.com` (R2
`south-indian-wallpapers`). Both are custom domains on the `hsrutility.com` zone; the legacy
`*.workers.dev` API host still answers for already-installed builds.

**Routes:** auth.ts · media.ts (gated signed-url + submissions) · payments.ts (PhonePe v2 Autopay) · me.ts · internal.ts
**Libs:** db.ts (Hyperdrive) · r2.ts (presign/copy) · jwt.ts · google.ts (idToken) · entitlement.ts (isPremium live read) · phonepe.ts
**Crons:** hourly (catalog + on-change canonical sweep ∥ autopay notify/execute) and daily 21:30 UTC
(unconditional canonical + submission sweeps) — detail in [cron.md](cron.md).

## API
JSON; errors `{error:{code,message}}`. Gated routes: `Authorization: Bearer <accessJWT>`.
Full route table with auth and semantics: [../workers/README.md](../workers/README.md).

**Auth:** POST /auth/{login,refresh,logout}
**Media** (premium-gated): POST /media/{signed-url,upload-url,confirm-upload}
**Payments:** POST /payments/{initiate,webhook,status,cancel} · GET /payments/callback
**Me** (scoped to sub): GET /me · /me/{subscription,submissions,referrals} · POST /me/profile · DELETE /me
**Internal** (CATALOG_BUILD_SECRET): POST /internal/{build-catalog,sweep-submissions,sweep-canonical,run-redemptions,refund}

`GET /me` returns identity **and** the subscription row in a single LEFT JOIN, so a cold start costs
one round-trip to a possibly-suspended Neon instead of two. `/me/subscription` still exists only for
builds shipped before that merge.

## Entitlement (live read from Neon, never authoritative in the JWT)
`isPremium = (status ∈ {trialing,active,cancelled} ∧ current_period_end > now()) ∨ users.reward_premium_until > now()`.
Cancelled keeps access until period end. Live read → purchase/refund apply instantly. No test bypass.
The access token's `prm` claim is a UI hint only; never gate on it.

**One trial per user:** `subscriptions.trial_end` is the consumed-marker (written once, kept forever).
NULL → PENNY_DROP setup + trial; NOT NULL → TRANSACTION setup with a real ₹199 first debit → straight
to `active`. Delete-account writes an HMAC tombstone so re-signup pre-seeds a consumed trial (no trial
farming). Endpoint facts: [phonepe.md](phonepe.md).

## Uploads (submissions)
upload-url presigns PUT to `user/<sub>/submissions/…` only. confirm-upload: kind = `wallpaper` (only),
HEAD-verifies the object, max 10 pending/user, upserts on unique file_key (idempotent retries).
Orphans reclaimed by sweep-submissions; pending rows expire after 30 d as a status flip, not a delete.

## Catalog generation
Source: `app_config.content_version` (Neon). Trigger: CMS mutation, `POST /internal/build-catalog`, or
the hourly cron (no-op if the version is unchanged). Output per scope (`wallpapers`, `ringtones`):
`catalog/<scope>/all_{page}.json` — ONE page set each, no per-category files — plus the shared
`catalog/version.json` and `catalog/app_config.json`. Rows are ordered `sort_order ASC,
created_at DESC NULLS LAST, id ASC`, so paging is deterministic.

A zero-row scope still writes a valid empty `all_1.json` (ringtones today), which makes a 404 there
mean "the build failed", not "no content". Every wallpaper item carries `category` and `feed_rank` —
the app's chips filter and `feedOrder()` orders client-side (no All/New tabs, never a static/live
filter), so the build's own row order is untouched by curation. Orphaned page files are deleted each
rebuild. Cache headers and the rules that serve them: [caching.md](caching.md).

**The `ringtones` scope stays backend-live while the app tab is parked** (v1 — no audio published;
[known-issues.md](known-issues.md)). Nothing here is conditional on the front end: keep building the
scope, keep `kind='ringtone'` on `/media/signed-url`, keep the `ringtones/` sweep prefix. Un-parking
must be a router change, never a backend rebuild.

Exposed keys are public by design (soft gate): wallpaper `full_key`, ringtone `audio_key` +
`cover_key`. (`catalog/catalog.json` in the bucket is the one-time import manifest, not read by the app.)

CMS: **separate worker + repo** (`hsr-cms`, `c:\Anish\Unified CMS`) serving Arul + Pakiza from one
login at `api.hsrutility.com/admin`. Server-rendered Hono JSX+HTMX, single operator (PBKDF2). Mutation
= bytes + row + version bump + rebuild + purge, atomically. It calls this worker via the `ARUL_API`
service binding → `/internal/build-catalog`; this worker exposes no `/admin` of its own.

## Schema (Neon) — detail in [data-model.md](data-model.md), DDL in `db/schema/`
users · subscriptions · wallpapers · ringtones · content_submissions · referrals · trial_tombstones ·
app_config (singleton). No RLS — the Worker scopes every parameterized query to the verified sub.

## Security
JWT HS256: access **60 m**, refresh 60 d rotating (jti denylisted in KV). idToken verified against
Google JWKS. PhonePe v2 OAuth (`O-Bearer`); webhook `Authorization: SHA256(user:pass)`, deduped by
orderId in KV. Secrets live in the Worker only — the app holds none.
