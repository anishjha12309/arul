# Backend Architecture

Browse = CDN-only ($0 egress). Writes = Workers → Neon. Neon holds per-user state only; the app never
touches it. API `https://arul-api.hsrutility.com` · CDN `https://arul-cdn.hsrutility.com` (R2
`south-indian-wallpapers`) — both custom domains on the `hsrutility.com` zone; the legacy
`*.workers.dev` API host still answers for already-installed builds, never disable it.
Crons: hourly (catalog + on-change canonical sweep ∥ autopay notify/execute) and daily 21:30 UTC
(unconditional canonical + submission sweeps) — [cron.md](cron.md).

## API
JSON; errors `{error:{code,message}}`; gated routes `Authorization: Bearer <accessJWT>`. THE route
table with auth + semantics is [../workers/README.md](../workers/README.md) — this file does not
restate it. `GET /me` returns identity, the subscription row AND the server-computed `premium` flag
in one LEFT JOIN, so a cold start costs one round-trip to a possibly-suspended Neon instead of two;
`/me/subscription` exists only for builds shipped before that merge. The app's gate reads that
`premium` flag — never re-derive it from the row (see §Entitlement for the drift that rule prevents).

## Entitlement (live read from Neon, never authoritative in the JWT)
`isPremium = (status ∈ {trialing,active,cancelled,pending} ∧ current_period_end > now()) ∨ users.reward_premium_until > now()`,
plus a **6 h debit grace** past `current_period_end` for `trialing`/`active` ONLY — the renewal debit
rides the hourly cron, so a strict cutoff closed the gate on every paying user for up to ~1 h at every
period boundary. `cancelled` gets NO grace (no debit is coming; period end IS the end), and dunning's
flip to `expired` ends grace instantly. `pending` counts (strict branch only) because a resubscribe
claims the user's ONE row — paid days must survive the attempt, and a failed setup RESTORES to
`cancelled` while the period lives, never `expired` (stripped a live trial on device 2026-08-12;
mechanics in [phonepe.md](phonepe.md)). Live read → purchase/refund apply instantly. No test bypass.
The rule's ONE home is `premiumPredicate` in `workers/src/lib/entitlement.ts`; the app consumes the
`premium` flag `GET /me` computes from it. A client-side copy of the rule drifted once — it missed
`reward_premium_until`, so reward-only referrers were paywalled while `/media/signed-url` would have
signed for them. Never re-create one. The access token's `prm` claim is a UI hint only; never gate on it.

**One trial per user:** `subscriptions.trial_end` is the consumed-marker (written once, kept forever).
NULL → PENNY_DROP setup + trial; NOT NULL → TRANSACTION setup with a real ₹199 first debit → straight
to `active`. Delete-account writes an HMAC tombstone so re-signup pre-seeds a consumed trial (no
trial farming). Endpoint facts: [phonepe.md](phonepe.md).

## Uploads (submissions)
upload-url presigns PUT to `user/<sub>/submissions/…` only. confirm-upload: kind = `wallpaper` (only),
HEAD-verifies the object, max 10 pending/user, upserts on unique file_key (idempotent retries).
Orphans reclaimed by sweep-submissions; pending rows expire after 30 d as a status flip, not a delete.

## Catalog generation
Source: `app_config.content_version` (Neon). Trigger: CMS mutation, `POST /internal/build-catalog`,
or the hourly cron (no-op if the version is unchanged). Output per scope (`wallpapers`, `ringtones`):
`catalog/<scope>/all_{page}.json` — ONE page set each, no per-category files — plus the shared
`catalog/version.json` + `catalog/app_config.json`. Rows ordered `sort_order ASC, created_at DESC
NULLS LAST, id ASC` so paging is deterministic; chips and `feedOrder()` are client-side, so curation
never touches the build's row order. **A zero-row scope still writes a valid empty `all_1.json`** —
a 404 there means "the build failed", never "no content". Orphaned page files are deleted each
rebuild. The backend is never conditional on the front end. Cache headers: [caching.md](caching.md).

Exposed keys are public by design (soft gate): wallpaper `full_key`, ringtone `audio_key` +
`cover_key`. `catalog/catalog.json` in the bucket is the one-time import manifest, not read by the app.

CMS: **separate worker + repo** (`hsr-cms`, `c:\Anish\Unified CMS`) serving Arul + Pakiza from one
login at `api.hsrutility.com/admin`. Mutation = bytes + row + version bump + rebuild + purge,
atomically, reaching this worker via the `ARUL_API` service binding → `/internal/build-catalog`.
This worker exposes no `/admin` of its own.

## Schema (Neon) — [data-model.md](data-model.md), DDL in `db/schema/`
users · subscriptions · wallpapers · ringtones · content_submissions · referrals · trial_tombstones ·
app_config (singleton). No RLS — the Worker scopes every parameterized query to the verified sub.

## Security
JWT HS256: access **60 m**, refresh 60 d rotating (jti denylisted in KV). idToken verified against
Google JWKS. PhonePe v2 OAuth (`O-Bearer`); webhook `Authorization: SHA256(user:pass)`, deduped by
orderId in KV. Secrets live in the Worker only — the app holds none.
