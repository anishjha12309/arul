# Backend architecture

Browse = CDN only (zero egress). Writes = Workers → Neon. Neon serves per-user state only at request
time — content rows are build-time input for the catalog. Hosts, routes, secrets and the CMS binding:
[../workers/README.md](../workers/README.md). Crons: [cron.md](cron.md). Columns:
[data-model.md](data-model.md).

## API

JSON; errors `{error:{code,message}}`; gated routes carry `Authorization: Bearer <accessJWT>`. **`GET /me`
returns identity, the subscription row AND the server-computed `premium` flag in one LEFT JOIN**, so a
cold start costs one round trip; `/me/subscription` exists only for builds shipped before that merge.

## Entitlement — a live read from Neon, never authoritative in the JWT

`isPremium = (status ∈ {trialing,active,cancelled,pending} ∧ current_period_end > now()) ∨
users.reward_premium_until > now()`, plus a **6 h debit grace** past `current_period_end` for
`trialing`/`active` ONLY — the renewal debit rides the cron, so a strict cutoff closed the gate on every
paying user at every period boundary. `cancelled` gets NO grace (no debit is coming), and dunning's flip
to `expired` ends grace at once. `pending` counts, strict branch only, because a resubscribe claims the
user's ONE row: paid days must survive the attempt, and a failed setup RESTORES rather than expiring
([phonepe.md](phonepe.md)). Live read → purchase, refund and expiry apply on the next gated tap. No test
bypass.

**The rule's ONE home is `premiumPredicate` in `workers/src/lib/entitlement.ts`**; the app consumes the
flag `GET /me` computes. A client-side copy drifted once — it missed `reward_premium_until` (legacy
referral credit and hand-set comps, ORed in forever), so reward-only users were paywalled while
`/media/signed-url` would have signed for them. Never re-create one. The access token's `prm` claim is a UI hint; never gate on it.

**The app's side of the gate:** `ensurePremium()` AWAITS `entitlementProvider.future` — a loading
snapshot must never bounce a premium user. A blocked action tracks `${action}_blocked_premium` and routes
STRAIGHT to `/premium?source=` — no nudge, sheet or interstitial. **A cached file is never a licence:**
re-applying or re-sharing bytes already on disk still calls `/media/signed-url`; offline with the bytes
on disk is the one pass-through. The "Manage subscription" row shows only for premium with a
`trialing`/`active`/`cancelled` row — the states `/premium` renders as a manage view; every other state
is a sell.

**One trial per user:** `trial_end` NULL → PENNY_DROP setup + trial; NOT NULL → a ₹199 TRANSACTION setup
→ straight to `active`. Delete-account writes an HMAC tombstone so a re-signup pre-seeds a consumed
trial. Delete order: revoke mandate(s) → tombstone → cascade → refresh-jti denylist.

## Uploads (submissions)

The pick is OUR channel (`MediaPickChannel`), not a plugin: the Photo Picker for a wallpaper (androidx
`PickVisualMedia`, which carries Google's own fallbacks), `ACTION_GET_CONTENT` on `audio/*` for a ringtone.
Neither needs a permission — keep `READ_MEDIA_*` out of the manifest or Play's Photo and Video Permissions
policy asks this app to justify it — and neither gets a `resolveActivity` pre-flight. The stream is copied
to `cacheDir/upload_picks/`, swept whole at every pick; Dart only sees the copy. Guard the picker CALL, not
the widget: the pick zone is a bare `GestureDetector`, and a double tap opened a second picker over the
first.

upload-url presigns PUT under `user/<sub>/submissions/…` only. confirm-upload takes kind `wallpaper` or
`ringtone` and byte-QCs against THAT kind's role — a fixed role rejected every ringtone; ≤10 pending per
user. **A category is required for both kinds, and the two draw from DIFFERENT sets** — the wrong set
files a row under a chip that tab never renders ([ringtones.md](ringtones.md)); `ringtones.category` is
NOT NULL, so the CMS vets it before copying. Moderation never ships a dimension-violating video: approve
copies bytes verbatim ([media-conventions.md](media-conventions.md)).

## Catalog generation

Trigger: a CMS mutation, `POST /internal/build-catalog`, or the hourly cron (a no-op while
`app_config.content_version` is unchanged). Output per scope (`wallpapers`, `ringtones`, `statuses`):
`catalog/<scope>/all_<page>.json`, ONE page set each at 200 rows/page, no per-category files — plus the
shared `catalog/version.json` (the pointer the app reads first, then `?v=<version>` on pages) and
`catalog/app_config.json` (the public config subset).

- **Row order is ONE SQL clause numbered into the catalog's `feed_rank` field** ([browse.md](browse.md)).
  Order server-side, because the catalog is the only channel that reaches installs that never update;
  chips stay client-side.
- **A zero-row scope still writes a valid empty `all_1.json`** — a 404 there means the build FAILED,
  never "no content". Orphaned page files are deleted each rebuild. Cache headers:
  [caching.md](caching.md).
- **The backend is never conditional on the front end:** every scope builds unconditionally; keep the
  ringtone scope, `kind='ringtone'` and the `ringtones/` sweep prefix whatever the app ships.
- **`version.json` commits only when EVERY scope builds**, so one failing scope freezes all of them for
  installs that never update. `statuses` therefore reads a missing table (42P01) as a valid empty page —
  the Worker may deploy before `30_statuses.sql`. A new scope copies that guard.
- **Fielded builds read only their own scope keys** — pages and `category_order.<scope>` alike — so a new
  kind gets its own scope, table and category kind, never rows in an old one.
- A CMS mutation is bytes + row + version bump in ONE transaction; the rebuild fires async over the
  `ARUL_API` binding and self-heals on the hourly cron.
- Exposed media keys are public by design (soft gate): wallpaper and status `full_key`, ringtone
  `audio_key`. The gate is the Worker's live entitlement read, never object privacy.
- `/media/signed-url` bumps ONE popularity counter per grant, chosen by `kind` + `action`: wallpaper
  `apply` → `apply_count`, every ringtone grant → `set_count`, status `share` → `share_count` and
  `download` → `download_count`; anything else (a wallpaper share, no `action` from an old build) bumps
  nothing, so a column keeps meaning what it says. A status bump also appends its `status_actions` row in
  the same statement ([data-model.md](data-model.md) §Popularity counters).

## Schema

Columns and their rules: [data-model.md](data-model.md); campaign-push tables: [push.md](push.md).

## Security

JWT HS256: access 60 m, refresh 60 d rotating, the old jti denylisted in KV. The access token carries
only `sub` plus the `prm` hint. The idToken is verified against Google's JWKS with `aud` = the WEB
client id, and the request nonce must match the token's ([auth.md](auth.md)). PhonePe: OAuth
`O-Bearer`; webhook `Authorization: SHA256(user:pass)`, deduped by (event, orderId) in KV
([phonepe-webhook.md](phonepe-webhook.md)). All SQL is parameterized and scoped to the verified sub;
upload keys are forced under `user/<sub>/`; canonical media is writable only through the CMS or
approval. Secrets live in the Worker only; the app holds none.

Google's JWKS is cached in memory and the colo's Cache API (Google's max-age, ≤ 6 h; jose's own set
ignores Cache-Control), and the last good set sits in KV `google:jwks` for a colo that never fetched:
a degraded colo's Google fetch is the one that times out. During an outage a copy under 24 h old
still verifies. A failed key fetch answers 503 `google_keys_unavailable`, never 401, which the
app would read as a bad account. The session is mirrored into Google's Block Store on every token
write and deleted with the tokens: it survives an uninstall (Backup on) and a device restore, so a
fresh install seeds it and the first 401 refreshes or ends it. Every fresh install's sheet waits on
the read (~0.3 s), so MainActivity starts it at engine setup on a first launch (the shared_preferences
cohort marker absent) and Dart collects it (~0.1 s left), capped at 600 ms. Block Store also survives `pm clear`: timing builds pass
`--dart-define=SESSION_RESTORE=false` or every run after the first skips the sheet.

The API client is dart:io with a 120 s idle socket and a warm-up when Google's surface shows — the
default 15 s idle dropped the splash's socket before a person picked an account. **cronet_http is a
dead end on this Gradle**: Play's Cronet pulls `cronet-api` and `cronet-shared`, both namespace
`org.chromium.net`, and the manifest merger fails (dart-lang/http#1932).
