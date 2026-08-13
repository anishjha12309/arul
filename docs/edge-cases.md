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
- [ ] Every card paints the `thumbs/` poster FIRST and keeps it mounted under the texture, which reveals only on `onRenderedFirstFrame` — so an undecoded live card is pixel-identical to a static one (no shimmer, no spinner). "Nothing is moving" is normally cold-cache latency; check the pool, not the catalog
- [ ] `BLASTBufferQueue … max frames` logspam while feed idles = benign compositor noise — do not chase

## Wallpaper apply
- [ ] Android 12+ recreate survived: `configChanges` `uiMode|colorMode` + `onConfigurationChanged` + dark launch theme — apply must NOT cold-restart (flutter/flutter#133722)
- [ ] Live apply downloads the MP4 locally first; feed decoder released only AFTER download completes, awaited before the native call ← apply notifier
- [ ] EVERY live apply opens the system chooser — no in-place swap (matches Pakiza). The user's "Set" tap is unobservable, so the notifier finishes IDLE and never claims success
- [ ] Live wallpaper is ONE engine on ONE record: the chooser commits `which=3`, so home and lock can never hold different live videos (verified on Nothing OS)
- [ ] OEM live-wallpaper restrictions caught → localized error, never a crash

## Auth
- [ ] Sign-in auto-launches FULL `authenticate()` on first frame — NON-NEGOTIABLE, never lightweight/silent
- [ ] EXACTLY ONE account picker per sign-in. `attemptLightweightAuthentication()` as a warm-up ahead of `authenticate()` is REVERTED (measured 2026-08-11): its "minimal UI" is a real Credential Manager bottom sheet on Android, so the user got a drawer that appeared, hung, then vanished before the real picker — and a stall-guard timeout on it added 2.5s of dead air. It saves ~230ms of Credential Manager cold start and costs a second visible sheet; do not retry it
- [ ] `google_sign_in` v7: `instance` → `initialize()` → `authenticate()`; idToken `aud` = WEB client id, verified in the Worker
- [ ] Sign-in bg video: shared ref-counted player with 2s dispose grace (screen swaps must not kill it)
- [ ] Auth failures surface a localized message + retry, never a stuck spinner

## Premium / payments (server is source of truth)
- [ ] `ensurePremium()` AWAITS `entitlementProvider.future` — a loading snapshot must never bounce a premium user ← `premium_gate.dart`
- [ ] Entitlement live-read from Neon on every gated action; never cached in the JWT
- [ ] `cancelled` keeps premium until period end (NO grace); `trialing`/`active` get a 6 h debit-grace past period end — the renewal debit rides the hourly cron, so a strict cutoff gated every payer at every boundary; `pending` with a live period keeps premium (a resubscribe claims the ONE row; paid days survive the attempt); `paused`/`expired` none; `reward_premium_until` ORed in ← `premiumPredicate`, the rule's ONE home
- [ ] A failed/abandoned setup RESTORES to `cancelled` while `current_period_end > now()`, never `expired` — expiring it stripped a cancelled-but-live trial on a backed-out resubscribe (device 2026-08-12); the setup-completed resurrect matches `('expired','cancelled')` so a paid approval racing the restore still grants ← `payments.ts` (all three failure paths)
- [ ] Unpause REARMS `next_debit_at` (COALESCE to `current_period_end`) and is scoped to `paused` rows; `/payments/status` heals lost pause AND unpause webhooks — a status-only unpause left an "Active" row no cron pass could ever bill again (zombie, 2026-08-13) ← `payments.ts` webhook + status reconcile
- [ ] The app's gate reads the server-computed `premium` flag from `GET /me` and NEVER re-derives the rule from the row — the client copy drifted (missed `reward_premium_until`) and paywalled reward-only referrers ← `entitlement_provider.dart`
- [ ] One trial ever: `trial_end` consumed-marker + delete-account HMAC tombstone (secret NEVER rotates); re-signup pre-seeds consumed trial → ₹199 TRANSACTION setup
- [ ] Endpoint contracts (SDK order token, working cancel path, 409 `setup_in_progress` on concurrent initiate, webhook dedupe) hold ← docs/phonepe.md
- [ ] Re-applying or re-sharing an ALREADY-CACHED wallpaper still calls `/media/signed-url` — a cache must never become a permanent licence; offline with bytes on disk is the one allowed pass-through ← `wallpaper_share_provider.dart`
- [ ] Blocked gated action tracks `${action}_blocked_premium` and routes STRAIGHT to `/premium?source=` — no nudge pill, no teaser sheet, no interstitial of any kind between the tap and the screen (owner's call, 2026-08-11; the once-per-session pill + bottom sheet the feed used to run were deleted, not disabled)
- [ ] Confirmation poll TOLERATES network failure: the app is backgrounded behind the UPI app, so `SocketException: Failed host lookup` mid-poll is normal, not terminal. Rethrowing it abandoned the budget, showed "Something went wrong", and nulled `_intentOrderId` so the resume checkpoint bailed too — a settled mandate with nobody watching (device 2026-08-11). Never reached the server at all → say confirmation is late, never the refund line ← `premium_purchase_provider.dart`
- [ ] Delete account: mandate revoke → tombstone → cascade → refresh-jti denylist

## Browse (category axis — a deliberate delta from Pakiza)
- [ ] CATEGORY chips only (All + 6); static/live interleave; unknown category falls into All, empty category → localized empty state, neither crashes
- [ ] Ordering model (All = use-count DESC, ties in catalog order; one pure `feedOrder()`/`orderedByUse()`) is owned by CLAUDE.md §5b. Pinned here: category order = `sort_order ASC, created_at DESC, id ASC`; the tie MUST break on catalog position because `List.sort` is NOT stable and `_syncFeed` compares served lists by ordered ids, so an unstable order re-points the pager under a scrolling user; zero counts ⇒ All is byte-identical to catalog order, which IS the intended default (pinned by test, not an accident)
- [ ] Apply-restore resolves its saved page index through `feedOrder()` ← `apply_restore.dart` — the index is a position in the SERVED list; raw catalog order restores the wrong wallpaper whenever the saved chip was All. A deep link resolves the SAME way (`maybeOpenDeepLink`, always on All) — [deep-links.md](deep-links.md)
- [ ] Reel card geometry lives ONLY in `feed_card_geometry.dart`, pinned by its test: 12dp gutters, **1:1.86 asked**, 14dp gap, 26 radius — 369×672 on 1080×2400, peek pinned at `minPeek` (40) and NO floor; `card + gap + peek + floor` fills the reel EXACTLY
- [ ] The card is HEIGHT-CLAMPED on a real phone, so `cardAspect` is a request and ~1.82 is what ships — read the solved size, never the constant. `gutter` therefore buys WIDTH only and flattens the realised aspect toward 1.78 as it shrinks; `minPeek` is the only knob that buys height
- [ ] The floor is bottom padding on the PAGER (zero on real phones, the sink for slack on tall screens) — anything screen-anchored must add `floor + peek + gap` or it lands behind the pager. Short-screen degradation: floor, then peek to `minPeek`, only then the card (a card taller than its viewport cannot snap)
- [ ] **1.78 (9:16) is a BOUNDARY, not a dial** — above it the crop is horizontal and cheap; below it it flips to top/bottom, costing crowns and feet on devotional art. `ViewerMedia.cropAlignment` biases the window UP for that case: dormant at ~1.82, LIVE on small screens (~1:1.31), so do not delete it as unused; poster, full image and video texture must share the alignment or the frame jumps on fade-in
- [ ] Live cards are marked by `LiveMark` ONLY — 24dp glass disc + play glyph, top-right, and **STATIC**: it shares a card with a live `Texture`, so the cheapest mark is one that never asks for a frame. Never text (the `LIVE` pill it replaced shipped untranslated English in 6 locales). Its inset is load-bearing: **22, not the action row's 14** — at 14 it rides the 26dp corner arc and reads as stuck to the rim. **No shadow** (owner's call, 2026-08-11): it shipped with the rail glyphs' dark halo as insurance against washing out on a white temple, and on the real catalog that halo read as a black smudge on EVERY wallpaper — a louder failure than the one it insured against. Contrast comes from a dark fill INSIDE the disc instead (next line); a shadow bleeds outside the object onto the artwork, which is the whole difference. Do not re-add one
- [ ] The two over-media glass objects share a RIM (`overMediaGlassBorder`) but NOT a fill, and that split is deliberate: the Share circle sits inside the bottom scrim so it can be the bright half (`overMediaGlassFill`, ivory); `LiveMark` sits on raw artwork where the ground is unknown, so it must be the dark half (`overMediaInkFill`). **Ivory chrome on a white marble temple is invisible at ANY alpha** — raising the alpha makes it whiter, not clearer. Never "unify" these two fills
- [ ] Skeleton and reel read the SAME geometry, or the card resizes when the first page lands
- [ ] Rejected card shapes, do not revisit: 1:1.71 full-bleed · 1:2.22 device-aspect · Pakiza's 1:1.63 verbatim · 1:1.40 short-and-wide

## Notifications (local only — there is no push channel)
Full contracts + traps: **[notifications.md](notifications.md)**. Hardest-biting: festival dates are DATA — a table
that runs out means **skip**, never extrapolate; `keep.xml` stops R8 stripping icons (breaks release builds ONLY);
QA tools gate on `isPlayInstall`, NOT `kDebugMode`.

## Ringtones (5 deities + `others`, no `temples`)
- [ ] The tab renders nothing until the WHOLE catalog is drained (category filtering is client-side), so every extra page is user-visible latency: build-catalog cuts ringtones at 200/page (one page for any realistic catalog), the notifier drains pages in a 4-wide pool (never serially — serial × 8 pages measured ~5 s), and `AppShell` warms the provider post-first-frame so the first tap lands on a ready list
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
- [ ] Privacy / Terms open the IN-APP reader (`/policy/:doc`, `PolicyDoc.route`) — never `launchUrl`. Reviewer's call 2026-08-12: leaving for Chrome is a rejection. It fences navigation to the policy host (everything else, incl. `mailto:`, goes out to the OS), hides the site's own navbar/footer, and holds the page back until it has — reveal early and the nav flashes. The document stays REMOTE (shared with Pakiza, one page to keep current), so this surface needs a real offline state
- [ ] Loading / empty / error state on every async surface, localized (all 6 locales)
- [ ] Worker error envelope `{error:{code,message}}` handled; offline → retry affordance
- [ ] Analytics only via `AnalyticsService`; ★ events mirror to GA4 `login`/`purchase` + Meta
- [ ] `allowBackup=false` + data-extraction rules + HTTPS-only network config
- [ ] `FLAG_SECURE` set in `MainActivity.onCreate` (not the manifest — must survive the Android 12+ apply recreate), **only when `isPlayInstall()`** which fails CLOSED — Play build blocks capture, debug/sideloaded stay visible for listing screenshots; `release-flag-secure-guard.js` denies any `.aab` that loses it
- [ ] No secrets in repo or APK — dart-defines only; `aapt dump badging` sanity when in doubt
- [ ] Worker vitest + `flutter test` green; `tsc --noEmit` clean; worker deployed
