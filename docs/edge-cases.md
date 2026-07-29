# Edge Cases & Must-Preserve Behavior

Permanent **regression contracts** — each line is a bug someone already paid for, and every box held
on-device as of the **1.0.0+20** release (2026-07-19). Walk them on-device before cutting a release.
Boxes stay unticked on purpose: unticked means "not re-checked for the release you are cutting now",
not "never done". `←` points at the code that implements the contract. They bind regardless of how
the UI is designed.

## Video feed (budget-SoC class — hardest-won)
- [ ] Live MP4s exactly 1024×1824 (w%128==0, h%32==0, ≤1088×1920 hw cap) ← docs/media-conventions.md
- [ ] ExoPlayer pool REUSES players — setMediaItem swap, never dispose+recreate per swipe ← `feedvideo/FeedVideoPlugin.kt`
- [ ] ONE process-global EventChannel hub — a second listener silently steals the sink ← `feed_video_player.dart`
- [ ] Silent software-decoder fallback detected (`onVideoDecoderInitialized`) → pool budget demoted 3→2, **floor 2**; only real codec errors may demote to 1 ← adaptive decoder budget
- [ ] Decoder capability APIs untrusted — attempt and degrade, never query and assume
- [ ] Shimmer until first decoded frame; NO poster thumbnails
- [ ] `BLASTBufferQueue … max frames` logspam while feed idles = benign compositor noise — do not chase

## Wallpaper apply
- [ ] Android 12+ recreate survived: `configChanges` `uiMode|colorMode` + `onConfigurationChanged` + dark launch theme — apply must NOT cold-restart (flutter/flutter#133722)
- [ ] Live apply downloads MP4 locally first; feed decoder released only AFTER download completes, awaited before the native call; skipped on in-place swap ← apply notifier
- [ ] In-place swap when our service is live on ANY slot (API 34 home+lock check); system picker only on true first-time
- [ ] OEM live-wallpaper restrictions caught → localized error, never a crash

## Auth
- [ ] Sign-in auto-launches FULL `authenticate()` on first frame — NON-NEGOTIABLE, never lightweight/silent
- [ ] `google_sign_in` v7: `instance` → `initialize()` → `authenticate()`; idToken `aud` = WEB client id, verified in the Worker
- [ ] Sign-in bg video: shared ref-counted player with 2s dispose grace (screen swaps must not kill it)
- [ ] Auth failures surface a localized message + retry, never a stuck spinner

## Premium / payments (server is source of truth; NO tests for this area — project rule)
- [ ] `ensurePremium()` AWAITS `entitlementProvider.future` — a loading snapshot must never bounce a premium user ← `premium_gate.dart`
- [ ] Entitlement live-read from Neon on every gated action; never cached in the JWT
- [ ] `cancelled` keeps premium until period end; `paused`/`expired` none; `reward_premium_until` ORed in
- [ ] One trial ever: `trial_end` consumed-marker + delete-account HMAC tombstone (secret NEVER rotates); re-signup pre-seeds consumed trial → ₹199 TRANSACTION setup
- [ ] SDK order token = `POST /checkout/v2/sdk/order`; working cancel = `/subscriptions/v2/{id}/cancel` (documented path 401s); 24h pre-debit notify cron; webhook deduped by orderId in KV ← docs/phonepe.md
- [ ] A second `/payments/initiate` while a setup is in flight returns 409 `setup_in_progress` — never a second live mandate
- [ ] Re-applying or re-sharing an ALREADY-CACHED wallpaper still calls `/media/signed-url` — a cache must never become a permanent licence. Offline with the bytes on disk is the one allowed pass-through ← `wallpaper_share_provider.dart`
- [ ] Blocked gated action tracks `${action}_blocked_premium` and routes `/premium?source=`
- [ ] Delete account: mandate revoke → tombstone → cascade → refresh-jti denylist

## Browse (category axis — a deliberate delta from Pakiza)
- [ ] Feed filters by CATEGORY chips (All + 6); static and live interleave — no All/New tabs, no static/live filter anywhere in the UI
- [ ] Every catalog item carries `category`; unknown/missing category never crashes the feed (falls into All)
- [ ] Empty category → localized empty state, not a blank feed

## Ringtones
- [ ] Setting a tone needs `WRITE_SETTINGS`: check `Settings.System.canWrite()` first, deep-link to
      `ACTION_MANAGE_WRITE_SETTINGS` when absent, never assume granted ← `MainActivity.kt:76-149`
      (`setRingtoneFromFile` re-checks and throws `SecurityException` at :149 — surface it localized)
- [ ] ONE shared `just_audio` `AudioPlayer` for ALL preview playback — starting a track stops the previous
      one, so two previews never overlap and only one decoder is held (the feed's video pool shares the
      device) ← `lib/features/ringtones/providers/ringtone_preview_provider.dart`
- [ ] `cover_key` is NULLABLE — a missing cover degrades to fallback art in app AND CMS, never a broken
      cell ← `db/schema/04_ringtones.sql:6-8`
- [ ] Preview is FREE (public `audio_key` straight from the CDN); only **Set** is premium-gated, through
      `/media/signed-url` with kind `ringtone` ← `workers/src/routes/media.ts:31`
- [ ] Set has a re-entrancy guard (same as apply/share) — a double tap must not run two set flows
      ← `lib/features/ringtones/providers/ringtone_set_provider.dart:91`

## Upload (wallpaper-only in Arul)
- [ ] confirm-upload accepts kind `wallpaper` ONLY; idempotent via unique `file_key` upsert; keys forced under `user/<sub>/`
- [ ] Upload form requires a category; approval copies to `wallpapers/<category>/…` and carries it onto the row
- [ ] Moderation approve NEVER ships a dimension-violating video as-is (bytes copy verbatim) — re-encode or reject

## Share
- [ ] Shares the ACTUAL media file (signed-URL gate, reuses apply's cache) + referral-link caption; WhatsApp absent → system sheet fallback

## Catalog / storage
- [ ] `version.json` is edge-cacheable (`public, max-age=30, stale-while-revalidate=300`), pages max-age=60 + `?v=` busting; stale content = rebuild, NEVER cache-purge ← docs/caching.md
- [ ] Orphaned catalog pages deleted each rebuild; the hourly sweep-canonical runs only after a fully-successful rebuild and refuses to act on an empty referenced-keys set; the daily 21:30 UTC sweep is the unconditional backstop ← `cron/sweep-canonical.ts`, docs/cron.md
- [ ] Hyperdrive query caching OFF (caused ~60s staleness once)
- [ ] Bucket/KV/DB are exclusively Arul's — sharing with another app = mutual media deletion
- [ ] R2 objects public BY DESIGN (soft gate); never add a "private" object to this bucket

## App-wide
- [ ] Loading / empty / error state on every async surface, localized (all 6 locales)
- [ ] Worker error envelope `{error:{code,message}}` handled; offline → retry affordance
- [ ] Analytics only via `AnalyticsService`; ★ events mirror to GA4 `login`/`purchase` + Meta
- [ ] `allowBackup=false` + data-extraction rules + HTTPS-only network config; **FLAG_SECURE added before public release**
- [ ] No secrets in repo or APK — dart-defines only; `aapt dump badging` sanity when in doubt
- [ ] Worker vitest suite + `flutter test` green; `tsc --noEmit` clean; worker deployed
