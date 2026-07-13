# Schema (Neon — source of truth: db/schema/, apply 01→03)

No ringtones table — Arul is wallpapers-only (differs from the reference; see port-map strip list).

**users:** id(PK) · google_sub(unique) · email · display_name · display_name_custom (true once user edits — login stops syncing from Google) · referral_code(unique) · referred_by(FK) · reward_premium_until (referral credit; read by isPremium, decoupled from subscriptions) · created_at

**subscriptions:** id(PK) · user_id(FK, unique — one row per user) · status(pending|trialing|active|paused|cancelled|expired) · plan · phonepe_subscription_id · merchant_subscription_id · merchant_order_id · phonepe_order_id · redemption_order_id · trial_end (**one-trial consumed-marker — written once, never cleared**) · current_period_end · next_debit_at · notified_at · retry_count · updated_at

**wallpapers:** id(PK) · title · type(static|live — a **rendering hint, never a filter**) · **category** (first-class Arul delta: `amman|ayyappan|murugan|perumal|sivan|temples`, free text + index so new categories need no migration) · tags[] (free-form extras) · full_key(R2, public) · mime · duration_ms(null for static) · width · height · bytes · is_published · sort_order (from manifest `scores.rank`) · created_at. No is_premium — the gate is in the Worker.

**Browse model (differs from the reference):** the feed filters by **category** — static and live wallpapers are interleaved in every category. There are NO All/New tabs and NO static-vs-live filter. `category` rides in each catalog page; filtering is client-side.

**content_submissions:** id(PK) · user_id(FK) · kind (only `'wallpaper'` in Arul — Worker validates) · file_key(R2, **unique** — confirm-upload upserts, idempotent) · title · **category** (required — the user picks one at upload; approval copies the object to `wallpapers/<category>/…` and carries it onto the wallpapers row) · status(pending|approved|rejected) · rejection_reason · reviewed_by(FK) · created_at

**referrals:** id(PK) · referrer_id(FK) · referred_user_id(FK, **unique** — referred once ever) · status(pending|subscribed|rewarded) · reward_days · created_at. Reward = bump referrer's users.reward_premium_until on friend's first paid debit.

**trial_tombstones:** google_sub_hash(PK — HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET), no PII) · trial_end · deleted_at. Written by DELETE /me; read by /auth/login to pre-seed a consumed trial on re-signup.

**app_config:** singleton(id=1) · content_version · prices(jsonb) · support_email · policy_urls(jsonb) · feature_flags(jsonb) · min_supported_version

## Data rules
- ALL apply/share actions are premium-gated in the Worker (/media/signed-url live entitlement check). Files stay public (soft gate) — wallpaper full_key.
- Browse reads catalog JSON only (never hits DB); gated actions live-read entitlement.
- User uploads live at `user/<sub>/submissions/…`; approval copies to a canonical key, then deletes the original.
