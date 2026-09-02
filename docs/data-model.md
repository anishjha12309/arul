# Schema (Neon)

Source of truth is `db/schema/`, applied in filename order, then `db/seed.sql`. Writing a change:
`.claude/skills/neon-migration/`. Feed order and the retired ranking columns: [browse.md](browse.md).

**users:** id(PK) · google_sub(unique) · email · display_name · display_name_custom (true once the
user edits — login then stops syncing from Google) · referral_code(unique) · referred_by(FK) ·
reward_premium_until (referral credit, read by `isPremium`, decoupled from subscriptions) ·
app_instance_id, meta_anon_id (**VESTIGIAL** — their only readers were the server GA4/Meta conversion
reporters, since deleted; nothing writes or reads them, and the columns stay because dropping them is
a migration) · created_at

**subscriptions:** id(PK) · user_id(FK, unique — one row per user) ·
status(pending|trialing|active|paused|cancelled|expired) · plan · phonepe_subscription_id (**may stay
NULL** when the webhook is lost and only status-reconcile runs; harmless, the cron addresses PhonePe
by our `merchant_subscription_id`) · merchant_subscription_id · merchant_order_id · phonepe_order_id ·
redemption_order_id · trial_end (**one-trial consumed-marker — written once, never cleared**) ·
current_period_end · next_debit_at · notified_at · retry_count · updated_at

**wallpapers:** id(PK) · title · type(static|live — a **rendering hint, never a filter**) ·
**category** (first-class Arul delta: `amman|ayyappan|murugan|perumal|sivan|temples`, free text plus
an index, so a new category is an insert and not a migration) · tags[] · full_key(R2, public) · mime ·
duration_ms(null for static) · width · height · bytes · is_published · sort_order · created_at ·
**apply_count**(bigint, default 0) · apply_score, scored_at (**retired, unread**). No `is_premium` —
the gate is in the Worker.

**ringtones:** id(PK) · title · **category** (the same browse axis, but its OWN six values —
[ringtones.md](ringtones.md)) · tags[] · audio_key(R2, public — `ringtones/<category>/<uuid>.mp3`) ·
**deity** (free text, nullable, indexed — DISPLAY ONLY, never a browse axis) · cover_key(R2, public,
nullable — **null on every row; nothing has ever been written under `ringtones/covers/`**) · mime
(kept in the catalog for set-file extension inference) · duration_ms · bytes · is_published ·
sort_order · created_at · **set_count**(bigint, default 0) · set_score, scored_at (**retired,
unread**). No `is_premium` — preview is free from the CDN; Set gates through `/media/signed-url` with
`kind='ringtone'`. Catalog scope `ringtones` strips `duration_ms`/`bytes`. Both keys live under the
`ringtones/` canonical prefix so the sweep protects audio and covers together.

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

**app_config:** singleton(id=1) · content_version · prices(jsonb) · support_email · policy_urls(jsonb)
· feature_flags(jsonb) · min_supported_version

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
