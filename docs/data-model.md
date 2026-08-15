# Schema (Neon — source of truth: db/schema/, apply *.sql in filename order, then seed.sql)

**users:** id(PK) · google_sub(unique) · email · display_name · display_name_custom (true once user edits — login stops syncing from Google) · referral_code(unique) · referred_by(FK) · reward_premium_until (referral credit; read by isPremium, decoupled from subscriptions) · app_instance_id (GA4 join key for server-side purchase reporting; uploaded at login/initiate, nullable) · created_at

**subscriptions:** id(PK) · user_id(FK, unique — one row per user) · status(pending|trialing|active|paused|cancelled|expired) · plan · phonepe_subscription_id · merchant_subscription_id · merchant_order_id · phonepe_order_id · redemption_order_id · trial_end (**one-trial consumed-marker — written once, never cleared**) · current_period_end · next_debit_at · notified_at · retry_count · updated_at

**wallpapers:** id(PK) · title · type(static|live — a **rendering hint, never a filter**) · **category** (first-class Arul delta: `amman|ayyappan|murugan|perumal|sivan|temples`, free text + index so new categories need no migration — **ringtones use a different six: the five deities, minus `temples`, plus `others`**, and each tab derives its chips from its own catalog, so the two differing is correct) · tags[] (free-form extras) · full_key(R2, public) · mime · duration_ms(null for static) · width · height · bytes · is_published · sort_order (imports leave it at the default 0) · created_at · **apply_count** (bigint, default 0 — order tier 2) · **feed_rank** (integer, NULLABLE, no default, no index — order tier 1, the admin's pin from the CMS ordering page; sparse 10/20/30… so a drag renumbers one row instead of cascading). No is_premium — the gate is in the Worker.

`feed_rank` NULL = unpinned, and that is ~every row. Nothing may backfill it or give it a default: an import writing no rank is exactly what stops a bulk drop from displacing the curated head. Never move curation back into `sort_order` — that coupling is what retired the first version.

`sort_order` drives CATEGORY-chip order. Imports write nothing into it (column default 0); the live rows currently carry a dense hand-written 1..N order from a one-off reorder tool (since deleted) — never reuse the column for anything else or every chip reorders.

**ringtones:** id(PK) · title · **category** (same first-class browse axis as wallpapers — chips, free text + index) · tags[] · audio_key(R2, public — `ringtones/<category>/<uuid>.mp3`) · **deity** (free text, nullable, indexed — DISPLAY ONLY: picks the bundled row art + the subtitle, never a browse axis. Finer than `category`, which stays coarse: `perumal` alone spans venkateswara/krishna/rama/narasimha, `amman` six goddesses. A null resolves in the app to the category's default art, then `fallback.webp` — so it never blocks an insert) · cover_key(R2, public, nullable — `ringtones/covers/<category>/<uuid>.jpg`; every live row ships null and the art is bundled, so nothing has ever been written under that prefix) · mime (kept in catalog — set-file extension inference) · duration_ms · bytes · is_published · sort_order · created_at. **set_count** (bigint, default 0 — order tier 2, same contract as `apply_count`) · **feed_rank** (integer, nullable — order tier 1, identical shape and identical NULL contract to the wallpaper column, so ONE comparator serves both tabs). Ordering matches wallpapers: sort_order ASC, created_at DESC. No is_premium — preview is free from CDN; "set as ringtone" gates via Worker /media/signed-url `kind='ringtone'`. Catalog scope `ringtones` → `catalog/ringtones/all_<page>.json` (strips duration_ms/bytes). Both keys live under the `ringtones/` canonical prefix so the hourly sweep protects audio and covers together.

**content_submissions:** id(PK) · user_id(FK) · kind (only `'wallpaper'` in Arul — Worker validates) · file_key(R2, **unique** — confirm-upload upserts, idempotent) · title · **category** (required — the user picks one at upload; approval copies the object to `wallpapers/<category>/…` and carries it onto the wallpapers row) · status(pending|approved|rejected) · rejection_reason · reviewed_by(FK) · created_at

**referrals:** id(PK) · referrer_id(FK) · referred_user_id(FK, **unique** — referred once ever) · status(pending|subscribed|rewarded) · reward_days · created_at. Reward = bump referrer's users.reward_premium_until on friend's first paid debit.

**trial_tombstones:** google_sub_hash(PK — HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET), no PII) · trial_end · deleted_at. Written by DELETE /me; read by /auth/login to pre-seed a consumed trial on re-signup.

**app_config:** singleton(id=1) · content_version · prices(jsonb) · support_email · policy_urls(jsonb) · feature_flags(jsonb) · min_supported_version

## Popularity counters
`apply_count` / `set_count` are incremented in `/media/signed-url` AFTER the entitlement check, on `c.executionCtx.waitUntil` so the app's most latency-sensitive route never waits on them. What the number means, exactly: a PREMIUM user was GRANTED the file. A blocked free user never reaches the route (403), the OS chooser can still be cancelled, and wallpaper SHARES are excluded via the request's `action` field (a WALLPAPER request with no `action` counts for nothing, so pre-2026-08-13 builds cannot pollute `apply_count`; every ringtone grant counts — ringtones have no share). No index — nothing filters or sorts on them in SQL; build-catalog full-scans and the app orders client-side.

Browse model (category axis, `feedOrder()` ordering) is owned by CLAUDE.md §5b — `category` and the counters ride in each catalog page; filtering and ordering are entirely client-side.

## Data rules
- ALL apply/share/set actions are premium-gated in the Worker (/media/signed-url live entitlement check). Files stay public (soft gate) — wallpaper full_key, ringtone audio_key/cover_key.
- Browse reads catalog JSON only (never hits DB); gated actions live-read entitlement.
- User uploads live at `user/<sub>/submissions/…`; approval copies to a canonical key, then deletes the original.
