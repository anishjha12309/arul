# Backend Architecture

Browse = CDN-only ($0 egress). Writes = Workers → Neon. At request time Neon serves per-user state
only — content rows are build-time input for the catalog, and the app never touches the DB. API
`https://arul-api.hsrutility.com` · CDN `https://arul-cdn.hsrutility.com` (R2
`south-indian-wallpapers`) — custom domains on the `hsrutility.com` zone, plus `arul.hsrutility.com`
for share landings and assetlinks ([deep-links.md](deep-links.md)). **The legacy `*.workers.dev` API
host still answers for already-installed builds — never disable it.**

Crons and what each trigger owns: [cron.md](cron.md).

## API
JSON; errors `{error:{code,message}}`; gated routes `Authorization: Bearer <accessJWT>`. THE route
table with auth and semantics is [../workers/README.md](../workers/README.md) — this file does not
restate it. `GET /me` returns identity, the subscription row AND the server-computed `premium` flag
in one LEFT JOIN, so a cold start costs one round-trip to a possibly-suspended Neon instead of two;
`/me/subscription` exists only for builds shipped before that merge.

## Entitlement — live read from Neon, never authoritative in the JWT
`isPremium = (status ∈ {trialing,active,cancelled,pending} ∧ current_period_end > now()) ∨
users.reward_premium_until > now()`, plus a **6 h debit grace** past `current_period_end` for
`trialing`/`active` ONLY — the renewal debit rides the cron, so a strict cutoff closed the gate on
every paying user at every period boundary. `cancelled` gets NO grace (no debit is coming; period end
IS the end), and dunning's flip to `expired` ends grace instantly. `pending` counts, in the strict
branch only, because a resubscribe claims the user's ONE row: paid days must survive the attempt, and
a failed setup RESTORES to `cancelled` while the period lives, never `expired` (mechanics in
[phonepe.md](phonepe.md)). Live read → purchase, refund and expiry apply instantly. No test bypass.

**The rule's ONE home is `premiumPredicate` in `workers/src/lib/entitlement.ts`**; the app consumes
the `premium` flag `GET /me` computes from it. A client-side copy drifted once — it missed
`reward_premium_until`, so reward-only referrers were paywalled while `/media/signed-url` would have
signed for them. Never re-create one. The access token's `prm` claim is a UI hint; never gate on it.

**One trial per user:** `subscriptions.trial_end` is the consumed-marker — written once, kept
forever. NULL → PENNY_DROP setup + trial; NOT NULL → TRANSACTION setup with a real ₹199 first debit →
straight to `active`. Delete-account writes an HMAC tombstone so re-signup pre-seeds a consumed trial
and trial farming is closed. Endpoint facts: [phonepe.md](phonepe.md).

## Uploads (submissions)
upload-url presigns PUT to `user/<sub>/submissions/…` only. confirm-upload takes kind `wallpaper` or
`ringtone` and byte-QCs against THAT kind's role — a fixed role rejects every ringtone; max 10
pending per user; upserts on unique `file_key`, so retries are idempotent. Approval needs a category
for both kinds, and the two draw from DIFFERENT sets ([ringtones.md](ringtones.md)). Orphans are
reclaimed by sweep-submissions; pending rows expire after 30 d as a status flip, not a delete.

## Catalog generation
Source: `app_config.content_version` (Neon). Trigger: a CMS mutation, `POST /internal/build-catalog`,
or the hourly cron (a no-op if the version is unchanged). Output per scope (`wallpapers`,
`ringtones`): `catalog/<scope>/all_{page}.json` — ONE page set each, 200 rows/page, no per-category
files — plus the shared `catalog/version.json` and `catalog/app_config.json`.

**Row order is one SQL clause, numbered into the catalog's `feed_rank` field — see
[browse.md](browse.md).** Order server-side because the catalog is the only channel that reaches
installs that never update; chips stay client-side.

**A zero-row scope still writes a valid empty `all_1.json`** — a 404 there means the build FAILED,
never "no content". Orphaned page files are deleted each rebuild. The backend is never conditional on
the front end. Cache headers: [caching.md](caching.md).

Exposed keys are public by design (soft gate): wallpaper `full_key`, ringtone `audio_key` and
`cover_key`. `catalog/catalog.json` in the bucket is the one-time import manifest and is not read by
the app.

CMS: **separate worker and repo** (`hsr-cms`, `c:\Anish\Unified CMS`) serving Arul and Pakiza from one
login at `api.hsrutility.com/admin`. A mutation is bytes + row + version bump in ONE transaction; the
rebuild fires async through the `ARUL_API` service binding → `/internal/build-catalog` and self-heals
on the hourly cron if it fails. No purge step — `?v=` cache-busting does that job. **This worker
exposes no `/admin` of its own.**

## Schema (Neon) — [data-model.md](data-model.md), DDL in `db/schema/`
users · subscriptions · wallpapers · ringtones · content_submissions · referrals · trial_tombstones ·
app_config (singleton). **No RLS** — the Worker scopes every parameterized query to the verified sub.

## Security
JWT HS256: access 60 m, refresh 60 d rotating, jti denylisted in KV. idToken verified against Google
JWKS, and the request nonce must match the token's ([auth.md](auth.md)). PhonePe v2 OAuth
(`O-Bearer`); webhook `Authorization: SHA256(user:pass)`, deduped by (event, orderId) in KV — **the
event MUST be in the key** ([phonepe.md](phonepe.md)). Secrets live in the Worker only; the app holds
none.
