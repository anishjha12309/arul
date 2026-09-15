# Schema (Neon)

Source of truth is `db/schema/`, applied in filename order, then `db/seed.sql`. Writing a change:
`.claude/skills/neon-migration/`. Feed order and the retired ranking columns: [browse.md](browse.md).

**users:** id(PK) · google_sub(unique) · email · display_name · display_name_custom (true once the
user edits — login then stops syncing from Google) · referral_code(unique) · referred_by(FK) ·
reward_premium_until (referral credit, read by `isPremium`, decoupled from subscriptions) ·
app_instance_id, meta_anon_id (**VESTIGIAL** — their only readers were the server GA4/Meta conversion
reporters, since deleted; nothing writes or reads them, and the columns stay because dropping them is
a migration) · **is_internal** (reporting-only, below) · created_at

**`is_internal` is set BY HAND and read only for reporting and test sends:** the unified CMS's
subscriptions page, and campaign push, where it is the "Test accounts" audience and keeps those phones
out of a campaign's Sent/Failed/Opened ([push.md](push.md)). No entitlement, payment, catalog or app
path reads it, so a wrong flag can never cost a user access — it can only move a number on an admin
page. It exists because the owner's own test trials and Google
Play's pre-launch robots are ~1.4% of trials but ~4% of CANCELLATIONS. **Enumerate exact addresses.**
An email substring is unusable on this user base: `%anish%` matches ~35 real paying users (kanishka,
manisharma, dhanish, nishanth) and `%test%` matches real ones too. The one safe pattern is
`%@cloudtestlabaccounts.com` — Google's Test Lab domain, never a person.

**subscriptions:** id(PK) · user_id(FK, unique — one row per user) ·
status(pending|trialing|active|paused|cancelled|expired) · plan · phonepe_subscription_id (**may stay
NULL** when the webhook is lost and only status-reconcile runs; harmless, the cron addresses PhonePe
by our `merchant_subscription_id`) · merchant_subscription_id · merchant_order_id · phonepe_order_id ·
redemption_order_id · trial_end (**one-trial consumed-marker — written once, never cleared**) ·
current_period_end · next_debit_at · notified_at · retry_count · updated_at · upi_target_app (the UPI
package the mandate was handed to at initiate, or `phonepe_page` for the SDK/hosted page; re-stamped
when an intent setup falls back, so it names the flow that RAN; NULL predates the column → PostHog
`subscription_active` reports `unknown`)

**Debit tracking on `subscriptions`:** `first_debit_at` · `debit_count` · `paid_paise` — written by EVERY
statement that grants a paid period (both settles, `run-redemptions`, and the repeat-subscriber ₹199 setup)
and read ONLY by the unified CMS's subscriptions page. `first_debit_at` is COALESCEd so a renewal never
moves it; NULL = never debited. Rows debited before the columns existed stay unstamped and NOTHING
backfills them — so the CMS does not read conversion off `first_debit_at` at all. It counts a granted
paid period instead (`current_period_end > trial_end`), which is true across the whole history, and
spends the stamps only on what the period cannot say: Renewed (`debit_count`) and Revenue
(`paid_paise`). Those two are LOWER BOUNDS for any cohort predating the columns, marked "≥" there.
Apply the schema BEFORE the Worker.

**wallpapers:** id(PK) · title · type(static|live — a **rendering hint, never a filter**) ·
**category** (first-class Arul delta: `amman|ayyappan|murugan|perumal|sivan|temples`, free text plus
an index, so a new category is an insert and not a migration) · tags[] · full_key(R2, public) · mime ·
duration_ms(null for static) · width · height · bytes · is_published · sort_order · created_at ·
**published_at** · **renewed_at** · **apply_count**(bigint, default 0) · apply_score, scored_at (**retired, unread**). No `is_premium` —
the gate is in the Worker.

**ringtones:** id(PK) · title · **category** (the same browse axis, but its OWN six values —
[ringtones.md](ringtones.md)) · tags[] · audio_key(R2, public — `ringtones/<category>/<uuid>.mp3`) ·
**deity** (free text, nullable, indexed — DISPLAY ONLY, never a browse axis) · cover_key(R2, public,
nullable — **null on every row; nothing has ever been written under `ringtones/covers/`**) · mime
(kept in the catalog for set-file extension inference) · duration_ms · bytes · is_published ·
sort_order · created_at · **published_at** · **renewed_at** · **set_count**(bigint, default 0) · set_score, scored_at (**retired,
unread**). No `is_premium` — preview is free from the CDN; Set gates through `/media/signed-url` with
`kind='ringtone'`. Catalog scope `ringtones` strips `duration_ms`/`bytes`. Both keys live under the
`ringtones/` canonical prefix so the sweep protects audio and covers together.

**`published_at` is stamped by a TRIGGER, never by a caller** (`stamp_published_at`, on both
tables). Three unrelated things publish — the unified CMS, the bulk importers, manual SQL — and all
of them do it by flipping `is_published`, so the stamp belongs on that flip and nowhere else. It is
the DEBUT date the app's New chip ages from, and deliberately not `created_at`, which is import time:
a batch imported in one month and published the next would otherwise be born too old to ever appear.
Stamped on the FIRST publish only (`published_at is null` guards it), so pulling a row to fix its
title and putting it back does not resurface it. No index — nothing filters on it; the app windows
client-side.

**`renewed_at` is the operator's Renew stamp** (nullable, no default, no backfill, no index —
`db/schema/19_renewed_at.sql`, 2026-09-15) and tier 1 of the New chip: inside the 7-day window,
renewed rows lead New, the last renewed on top ([browse.md](browse.md)). It has ONE writer, the
unified CMS's Feed order page, and it is deliberately not a trigger — resurfacing is an act, never a
side effect of publishing. That same UPDATE re-stamps `published_at = now()` (the trigger keeps an
explicit value), so builds before 1.0.0+78 still window the row into New; the debut date is lost, by
the owner's choice. This replaces clearing `published_at` by hand as the way to resurface a row.
Unpublishing does not clear it.

**`feed_rank` is a nullable `integer` on BOTH tables** again (dropped 2026-08-25, restored
2026-09-02): the hand pin the unified CMS writes, and tier 1 of the feed order. NULL means unpinned
and is the state of ~every row; never fold it to 0, and never give the column a default or a
backfill. The catalog JSON field of the same name is a different thing — a position `build-catalog`
computes over the finished order ([browse.md](browse.md)).

**`sort_order` participates in no ordering decision that reaches a user.** Imports own it — the
ringtone importer writes it, the wallpaper importer leaves the default — and the CMS still edits it,
but nothing reads it for feed order. Never move curation back into it; that coupling is what retired
the first ordering scheme.

**content_submissions:** id(PK) · user_id(FK) · kind (`wallpaper` or `ringtone` — the Worker
validates; both kinds are live) · file_key(R2, **unique** — confirm-upload upserts, so retries are
idempotent) · title · **category** (the user picks one at upload; approval copies the object into
that category's prefix and carries it onto the content row) · status(pending|approved|rejected) ·
rejection_reason · reviewed_by(FK) · created_at

**referrals:** id(PK) · referrer_id(FK) · referred_user_id(FK, **unique** — referred once ever) ·
status(pending|subscribed|rewarded) · reward_days · created_at. The reward bumps the referrer's
`users.reward_premium_until` on the friend's first paid debit, once, and a later cancellation does
not claw it back.

**trial_tombstones:** google_sub_hash(PK — HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET), no PII) ·
trial_end · deleted_at. Written by `DELETE /me`; read by `/auth/login` to pre-seed a consumed trial
on re-signup.

**categories:** (slug, kind)(PK) · is_published · picker_order · created_at · published_at.
**Written and read ONLY by the unified CMS** — no Worker route and no cron touches it, and
`build-catalog` must never start: a category reaches the app by being on a PUBLISHED ROW, since the
chips are derived from the catalog's items, so there is nothing here for the catalog to carry. It
holds only OPERATOR-CREATED categories, staged unpublished so their rows can be uploaded and reviewed
before anything appears in a chip; the CMS keeps those rows unpublished until the flag flips, and
publishing flips both in one transaction with the `content_version` bump. The seeded slugs and
anything already on a content row are never inserted, so nothing live can be retracted from here.
`picker_order` sorts the CMS's dropdowns only — chips are sorted by `compareBrowseCategories`.

**app_config:** singleton(id=1) · content_version · prices(jsonb) · support_email · policy_urls(jsonb)
· feature_flags(jsonb) · min_supported_version

**Campaign push** ([push.md](push.md)): push_devices(fid PK, user_id NULL until the phone signs in) ·
push_campaigns (color, expires_hours 1|6|24) · push_deliveries ((campaign_id, fid) PK — the
idempotency) · push_opens ((campaign_id, user_id) PK — an open is per PERSON, not per phone). All
additive: no existing table changed in a way a shipped build can see, so every build in the field kept
working. A device row is deleted on a 404 UNREGISTERED and after 270 idle days, never on a quota error.

## Popularity counters
`apply_count` / `set_count` are incremented in `/media/signed-url` **after** the entitlement check, on
`c.executionCtx.waitUntil`, so the app's most latency-sensitive route never waits on them. What the
number means exactly: **a PREMIUM user was GRANTED the file.** A blocked free user never reaches the
route (403), the OS chooser can still be cancelled, and wallpaper SHARES are excluded via the
request's `action` field — a wallpaper request with no `action` counts for nothing, so builds
predating that field cannot pollute `apply_count`. Every ringtone grant counts; ringtones have no
share.

They carry no index: nothing filters on them, and `build-catalog` full-scans once an hour.

## Data rules
- ALL apply/share/set actions are premium-gated in the Worker, on a live entitlement read. Files stay
  public (soft gate) — wallpaper `full_key`, ringtone `audio_key`/`cover_key`.
- Browse reads catalog JSON only and never hits the DB; gated actions live-read entitlement.
- User uploads live at `user/<sub>/submissions/…`; approval copies to a canonical key, then deletes
  the original.
