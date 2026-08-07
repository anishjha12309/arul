# Edge Cases & Must-Preserve Behavior

Permanent **regression contracts** — each line is a bug someone already paid for. Walk them on-device before cutting
a release; boxes stay unticked on purpose (unticked = "not re-checked for the release you are cutting now").
`←` points at the implementing code. They bind regardless of UI design.

## Video feed (budget-SoC class — hardest-won)
- [ ] Live MP4s exactly 1024×1824 (w%128==0, h%32==0, ≤1088×1920 hw cap) ← docs/media-conventions.md
- [ ] ExoPlayer pool REUSES players — setMediaItem swap, never dispose+recreate per swipe ← `feedvideo/FeedVideoPlugin.kt`
- [ ] ONE process-global EventChannel hub — a second listener silently steals the sink ← `feed_video_player.dart`
- [ ] Silent software-decoder fallback detected (`onVideoDecoderInitialized`) → pool budget demoted 3→2, **floor 2**; only real codec errors may demote to 1
- [ ] Decoder capability APIs untrusted — attempt and degrade, never query and assume
- [ ] Shimmer until first decoded frame; NO poster thumbnails
- [ ] `BLASTBufferQueue … max frames` logspam while feed idles = benign compositor noise — do not chase

## Wallpaper apply
- [ ] Android 12+ recreate survived: `configChanges` `uiMode|colorMode` + `onConfigurationChanged` + dark launch theme — apply must NOT cold-restart (flutter/flutter#133722)
- [ ] Live apply downloads the MP4 locally first; feed decoder released only AFTER download completes, awaited before the native call ← apply notifier
- [ ] EVERY live apply opens the system chooser — no in-place swap (matches Pakiza). The user's "Set" tap is unobservable, so the notifier finishes IDLE and never claims success
- [ ] Live wallpaper is ONE engine on ONE record: the chooser commits `which=3`, so home and lock can never hold different live videos (verified on Nothing OS)
- [ ] OEM live-wallpaper restrictions caught → localized error, never a crash

## Auth
- [ ] Sign-in auto-launches FULL `authenticate()` on first frame — NON-NEGOTIABLE, never lightweight/silent
- [ ] `google_sign_in` v7: `instance` → `initialize()` → `authenticate()`; idToken `aud` = WEB client id, verified in the Worker
- [ ] Sign-in bg video: shared ref-counted player with 2s dispose grace (screen swaps must not kill it)
- [ ] Auth failures surface a localized message + retry, never a stuck spinner

## Premium / payments (server is source of truth)
- [ ] `ensurePremium()` AWAITS `entitlementProvider.future` — a loading snapshot must never bounce a premium user ← `premium_gate.dart`
- [ ] Entitlement live-read from Neon on every gated action; never cached in the JWT
- [ ] `cancelled` keeps premium until period end; `paused`/`expired` none; `reward_premium_until` ORed in
- [ ] One trial ever: `trial_end` consumed-marker + delete-account HMAC tombstone (secret NEVER rotates); re-signup pre-seeds consumed trial → ₹199 TRANSACTION setup
- [ ] Endpoint contracts (SDK order token, working cancel path, 409 `setup_in_progress` on concurrent initiate, webhook dedupe) hold ← docs/phonepe.md
- [ ] Re-applying or re-sharing an ALREADY-CACHED wallpaper still calls `/media/signed-url` — a cache must never become a permanent licence; offline with bytes on disk is the one allowed pass-through ← `wallpaper_share_provider.dart`
- [ ] Blocked gated action tracks `${action}_blocked_premium` and routes `/premium?source=`
- [ ] Delete account: mandate revoke → tombstone → cascade → refresh-jti denylist

## Browse (category axis — a deliberate delta from Pakiza)
- [ ] CATEGORY chips only (All + 6); static/live interleave; unknown category falls into All, empty category → localized empty state, neither crashes
- [ ] Ordering model (curated `feed_rank` head + stable-shuffle tail, one pure `feedOrder()`) is owned by CLAUDE.md §5b. Pinned here: category order = `sort_order ASC, created_at DESC, id ASC`; the shuffle is a hand-rolled FNV-1a of the row id (`String.hashCode` is NOT stable across Dart releases); `_syncFeed` compares served lists by ordered ids, so a per-call order re-points the pager under a scrolling user; all-NULL ranks ⇒ byte-identical to the pure shuffle (held by the golden pin)
- [ ] Apply-restore resolves its saved page index through `feedOrder()` ← `apply_restore.dart` — the index is a position in the SERVED list; raw catalog order restores the wrong wallpaper whenever the saved chip was All
- [ ] Reel card geometry has ONE knob ← `feed_card_geometry.dart`, pinned by its test: 20dp gutters, **1:1.86** card, 14dp gap, 26 radius — 353×656 on 1080×2400 with ~56dp peek and NO floor; `card + gap + peek + floor` fills the reel EXACTLY
- [ ] The floor is bottom padding on the PAGER (zero on real phones, the sink for slack on tall screens) — anything screen-anchored must add `floor + peek + gap` or it lands behind the pager. Short-screen degradation: floor, then peek to `minPeek`, only then the card (a card taller than its viewport cannot snap)
- [ ] **1.78 (9:16) is a BOUNDARY, not a dial** — above it the crop is horizontal and cheap; below it it flips to top/bottom, costing crowns and feet on devotional art. `ViewerMedia.cropAlignment` biases the window UP for that case: dormant at 1.86, LIVE on small screens (~1:1.36), so do not delete it as unused; poster, full image and video texture must share the alignment or the frame jumps on fade-in
- [ ] Skeleton and reel read the SAME geometry, or the card resizes when the first page lands
- [ ] Rejected card shapes, do not revisit: 1:1.71 full-bleed · 1:2.22 device-aspect · Pakiza's 1:1.63 verbatim · 1:1.40 short-and-wide

## Notifications (local only — there is no push channel)
Full contracts + traps: **[notifications.md](notifications.md)**. Hardest-biting: festival dates are DATA — a table
that runs out means **skip**, never extrapolate; `keep.xml` stops R8 stripping icons (breaks release builds ONLY);
QA tools gate on `isPlayInstall`, NOT `kDebugMode`.

## Ringtones (5 deities + `others`, no `temples`)
- [ ] Set needs `WRITE_SETTINGS`: check `Settings.System.canWrite()` first, deep-link to `ACTION_MANAGE_WRITE_SETTINGS` when absent ← `MainActivity.kt` (`setRingtoneFromFile` re-checks; surface `SecurityException` localized). The deep-link walks a FALLBACK CHAIN (per-package → app-list → app details) — some MIUI/ColorOS settings apps throw on the per-package form
- [ ] **Below API 29 the tone is COPIED into the public Ringtones dir** and THAT path registered on the EXTERNAL volume — the app-private path is unreadable by the ringtone player, and the `internal` volume never validates as a ringtone (both seen on-device in Pakiza). Needs `WRITE_EXTERNAL_STORAGE` (capped `maxSdkVersion=28`), runtime-prompted at the first Set, never at launch
- [ ] Picker name = the CATALOG TITLE threaded through the channel, never the downloaded filename; `mime` rides along (some OEM scanners re-derive type from the extension and misindex a disagreeing row)
- [ ] Stale-row cleanup must NEVER abort the set — pre-reinstall rows throw `RecoverableSecurityException`; skip them and let MediaStore uniquify, or re-setting any pre-reinstall tone breaks permanently
- [ ] ONE shared `just_audio` player for ALL previews — starting a track stops the previous; only one decoder held (the feed's video pool shares the device) ← `ringtone_preview_provider.dart`
- [ ] Row art is DRAWN, never fetched: kolam medallion hashed from the ringtone **id** (motif from **category**) so a tile never re-rolls ← `ringtone_medallion.dart`; `cover_key` stays nullable. Every tile draws the SAME skeleton — parameters permute, never a structural coin-flip
- [ ] Every now-playing affordance derives from the ONE `currentId`; clearing it stops the audio, never just dims the row
- [ ] Preview is FREE (public `audio_key` from CDN); only **Set** gates, via `/media/signed-url` kind `ringtone` ← `workers/src/routes/media.ts`
- [ ] Set has a re-entrancy guard (same as apply/share) — a double tap must not run two set flows ← `ringtone_set_provider.dart`

## Upload (wallpaper-only in Arul)
- [ ] confirm-upload accepts kind `wallpaper` ONLY; idempotent via unique `file_key` upsert; keys forced under `user/<sub>/`
- [ ] Upload form requires a category; approval copies to `wallpapers/<category>/…` and carries it onto the row
- [ ] Moderation approve NEVER ships a dimension-violating video as-is (bytes copy verbatim) — re-encode or reject

## Share
Full contracts + copy rules: **[share.md](share.md)**. Hardest-biting: **exactly one link leaves per share**, owned
by the caption; WhatsApp-first uses a DIFFERENT mechanism per path (the text-only deep link silently drops the
file); the live watermark needs **API 31** — below it the share ships clean rather than crashing ([known-issues.md](known-issues.md)).

## Catalog / storage
- [ ] `version.json` edge-cacheable (`public, max-age=30, stale-while-revalidate=300`), pages max-age=60 + `?v=`; stale content = rebuild, NEVER cache-purge ← docs/caching.md
- [ ] Orphaned pages deleted each rebuild; hourly sweep-canonical runs only after a fully-successful rebuild and refuses an empty referenced-keys set; the daily 21:30 UTC sweep is the unconditional backstop ← `cron/sweep-canonical.ts`
- [ ] Hyperdrive query caching OFF (caused ~60s staleness once)
- [ ] Bucket/KV/DB are exclusively Arul's — sharing with another app = mutual media deletion. R2 objects public BY DESIGN (soft gate); never add a "private" object

## App-wide
- [ ] Loading / empty / error state on every async surface, localized (all 6 locales)
- [ ] Worker error envelope `{error:{code,message}}` handled; offline → retry affordance
- [ ] Analytics only via `AnalyticsService`; ★ events mirror to GA4 `login`/`purchase` + Meta
- [ ] `allowBackup=false` + data-extraction rules + HTTPS-only network config
- [ ] `FLAG_SECURE` set in `MainActivity.onCreate` (not the manifest — must survive the Android 12+ apply recreate), **only when `isPlayInstall()`** which fails CLOSED — Play build blocks capture, debug/sideloaded stay visible for listing screenshots; `release-flag-secure-guard.js` denies any `.aab` that loses it
- [ ] No secrets in repo or APK — dart-defines only; `aapt dump badging` sanity when in doubt
- [ ] Worker vitest + `flutter test` green; `tsc --noEmit` clean; worker deployed
