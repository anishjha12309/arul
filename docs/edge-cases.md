# Edge Cases & Must-Preserve Behavior

The port is NOT done until every box holds on-device. `←` points into the reference (c:\Anish\Pakiza).
These are regressions that actually happened once — each line is a bug someone already paid for.
They bind regardless of how different Arul's UI looks.

## Video feed (budget-SoC class — hardest-won)
- [ ] Live MP4s exactly 1024×1824 (w%128==0, h%32==0, ≤1088×1920 hw cap) ← docs/media-conventions.md + `wallpaper-media-spec.md`
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
- [ ] SDK order token = `POST /checkout/v2/sdk/order`; working cancel = `/subscriptions/v2/{id}/cancel` (documented path 401s); 24h pre-debit notify cron; webhook deduped by orderId in KV
- [ ] Blocked gated action tracks `${action}_blocked_premium` and routes `/premium?source=`
- [ ] Delete account: mandate revoke → tombstone → cascade → refresh-jti denylist

## Browse (category axis — Arul delta)
- [ ] Feed filters by CATEGORY chips (All + 6); static and live interleave — no All/New tabs, no static/live filter anywhere in the UI
- [ ] Every catalog item carries `category`; unknown/missing category never crashes the feed (falls into All)
- [ ] Empty category → localized empty state, not a blank feed

## Upload (wallpaper-only in Arul)
- [ ] confirm-upload accepts kind `wallpaper` ONLY; idempotent via unique `file_key` upsert; keys forced under `user/<sub>/`
- [ ] Upload form requires a category; approval copies to `wallpapers/<category>/…` and carries it onto the row
- [ ] Moderation approve NEVER ships a dimension-violating video as-is (bytes copy verbatim) — re-encode or reject

## Share
- [ ] Shares the ACTUAL media file (signed-URL gate, reuses apply's cache) + referral-link caption; WhatsApp absent → system sheet fallback

## Catalog / storage
- [ ] `version.json` no-store; pages max-age=60 + `?v=` busting; stale content = rebuild, NEVER cache-purge
- [ ] Orphaned catalog pages deleted each rebuild; sweep-canonical runs only after a fully-successful rebuild and refuses to act on an empty referenced-keys set ← `cron/sweep-canonical.ts`
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
