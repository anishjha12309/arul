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
- [ ] Live apply downloads MP4 locally first; feed decoder released only AFTER download completes, awaited before the native call ← apply notifier
- [ ] EVERY live apply opens the system live-wallpaper chooser — no in-place swap (matches Pakiza, 2026-07-30). The user's "Set" tap is unobservable, so the notifier finishes IDLE and never claims success
- [ ] Live wallpaper is ONE engine on ONE record: the chooser commits `which=3` (home+lock together), so home and lock can never hold different live videos — verified on Nothing OS, where the OEM's own live wallpaper does the same
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
- [ ] **Two orderings, one function** — `feedOrder()` in `catalog_providers.dart` is the ONLY definition.
      A category chip serves catalog order (`sort_order ASC, created_at DESC, id ASC` = newest first).
      **All serves a curated block, then a stable shuffle** of everything else. The shuffle is a
      hand-rolled FNV-1a of the row id, because catalog order puts a whole bulk import at the head: an
      import is one transaction, so its rows tie on `sort_order` AND `created_at` and land consecutively
      (a 30-item batch owned the first 30 slots).
- [ ] The curated block is `wallpapers.feed_rank` (nullable int, sparse 10/20/30… from the CMS Feed-order
      panel), ASC with `id` breaking a tie; it rides in the catalog JSON so a save propagates like a
      publish. **Uncurated rows go in the TAIL, never on top** — a fresh import as a consecutive head
      block is the defect the shuffle exists to kill. All ranks NULL ⇒ byte-identical to the pure shuffle
      (the shipped state, held by the golden pin). Category chips ignore `feed_rank`.
- [ ] The All order must stay a pure function of catalog CONTENT — never `List.shuffle`, never seeded by
      time or `content_version`. It is recomputed on every catalog emission (cold start, background
      revalidate, pull-refresh, hourly cron), and `_syncFeed` compares served lists by ordered ids: a
      per-call order re-points the pager and the video pool under a scrolling user. `String.hashCode` is
      not stable across Dart releases — that is why the hash is hand-rolled.
- [ ] Apply-restore resolves its saved page index through `feedOrder()` too ← `apply_restore.dart`. The
      index is a position in the list the feed SERVES; validating it against raw catalog order restores
      the user onto a different wallpaper whenever the saved chip was All.
- [ ] **The reel card is TALL on tight gutters** (owner's call from rendered mockups, 2026-07-30) ←
      `feed_card_geometry.dart`, pinned by `feed_card_geometry_test.dart`. 20dp gutters, a **1:1.86**
      card, 14dp gap, 26 radius, 180 scrim, 14 action inset; **353×656** on a 1080×2400 phone with a
      ~56dp peek and NO floor. `card + gap + peek + floor` fills the reel EXACTLY.
- [ ] The floor is bottom padding on the PAGER, not part of it. At this aspect it is **zero on every
      real phone** — the card eats the reel — but it is the sink for slack on taller screens and returns
      the moment `cardAspect` is lowered. Anything screen-anchored (the gate nudge, the end-of-feed mark)
      must still add `floor + peek + gap`, or it lands behind the pager.
- [ ] Degradation order on a short screen: **floor, then peek down to `minPeek`, and only then the
      card**. A card taller than its own viewport cannot snap, so it must never overflow.
- [ ] **1.78 (9:16) is a BOUNDARY, not a dial.** Above it the crop is horizontal and cheap — at 1:1.86
      about 4.4% comes off the left and right margins. Below it the crop flips to top/bottom, which on
      devotional art costs crowns and feet. `ViewerMedia.cropAlignment` biases the window UP for exactly
      that case: dormant at 1.86, but LIVE on a small screen where the card is forced squarer (~1:1.36),
      so do not delete it as unused. The poster, the full image and the video texture must all share that
      alignment or the frame visibly jumps when the real media fades in.
- [ ] Skeleton and reel read the SAME geometry, or the card visibly resizes when the first page lands.
- [ ] Four rejected shapes, do not revisit: full-bleed width (1:1.71) read as edge-to-edge; the DEVICE
      aspect (1:2.22) was a sliver that cropped the sides and crowded the action row; Pakiza's card
      verbatim (1:1.63, 18dp gutters) too tall and tight; short-and-wide (1:1.40, 32dp gutters) cost 21%
      off the top and bottom.

## Notifications (local only — there is no push channel)
Full checklist + the on-device testing, chime and panchangam procedures:
**[notifications.md](notifications.md)**. The three that bite hardest: festival dates are DATA and a
table that runs out means **skip**, never extrapolate; `res/raw/keep.xml` is what stops R8 stripping the
icons and breaking release builds only; and the QA tools are gated on `isPlayInstall`, NOT `kDebugMode`,
so they exist in a sideloaded release APK — the only build where those failures reproduce.

## Ringtones — LIVE since 2026-08-05 (30 tracks), walk these
- [ ] Setting a tone needs `WRITE_SETTINGS`: check `Settings.System.canWrite()` first, deep-link to
      `ACTION_MANAGE_WRITE_SETTINGS` when absent, never assume granted ← `MainActivity.kt`
      (`setRingtoneFromFile` re-checks and throws `SecurityException` — surface it localized). The
      deep-link walks a FALLBACK CHAIN (per-package → app-list → app details): some MIUI/ColorOS
      settings apps do not resolve the per-package form and `startActivity` throws there.
- [ ] **Below API 29 the tone is COPIED into the public Ringtones dir** and THAT path registered on
      the EXTERNAL volume: the app-private cache path is unreadable by the ringtone player and routes
      the row to the read-only `internal` volume, which never validates as a ringtone (both seen
      on-device in Pakiza). Needs `WRITE_EXTERNAL_STORAGE` (capped `maxSdkVersion=28`),
      runtime-prompted at the first Set and resumed in `onRequestPermissionsResult` — never at launch.
- [ ] Picker name = the CATALOG TITLE threaded through the channel and sanitized natively, never the
      downloaded filename (the ringtone id). `mime` rides along: some OEM scanners re-derive type
      from the extension and misindex a row whose MIME disagrees.
- [ ] Stale-row cleanup before re-insert must NEVER abort the set — rows from a previous install
      throw `RecoverableSecurityException`; skip them and let MediaStore uniquify the name, or
      re-setting any pre-reinstall tone breaks permanently.
- [ ] ONE shared `just_audio` `AudioPlayer` for ALL preview playback — starting a track stops the previous
      one, so two previews never overlap and only one decoder is held (the feed's video pool shares the
      device) ← `lib/features/ringtones/providers/ringtone_preview_provider.dart`
- [ ] Row art is DRAWN, never fetched: a kolam medallion hashed from the ringtone **id** (ground, dot
      count, rotation) with the motif from its **category**, so a tile never re-rolls across launches or
      when a filter reorders the list ← `ringtone_medallion.dart`. `cover_key` stays nullable, CMS-only.
      Every tile draws the SAME skeleton — only the parameters permute; never add a structural coin-flip
      or the list reads as individually-styled rows rather than one system.
- [ ] Every now-playing affordance — row fill, border, title, button, cover overlay — derives from the ONE
      `currentId`; clearing it stops the audio, never just dims the row
- [ ] Preview is FREE (public `audio_key` straight from the CDN); only **Set** is premium-gated, through
      `/media/signed-url` with kind `ringtone` ← `workers/src/routes/media.ts:31`
- [ ] Set has a re-entrancy guard (same as apply/share) — a double tap must not run two set flows
      ← `lib/features/ringtones/providers/ringtone_set_provider.dart:91`

## Upload (wallpaper-only in Arul)
- [ ] confirm-upload accepts kind `wallpaper` ONLY; idempotent via unique `file_key` upsert; keys forced under `user/<sub>/`
- [ ] Upload form requires a category; approval copies to `wallpapers/<category>/…` and carries it onto the row
- [ ] Moderation approve NEVER ships a dimension-violating video as-is (bytes copy verbatim) — re-encode or reject

## Share
Full checklist + the copy rules: **[share.md](share.md)**. The three that bite hardest: **exactly one link
leaves the app per share**, owned by the caption; WhatsApp-first uses a DIFFERENT mechanism per path,
because the text-only deep link silently drops a wallpaper's file; and the live-video watermark needs
**API 31** — below it the share ships clean rather than crashing ([known-issues.md](known-issues.md)).

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
- [ ] `allowBackup=false` + data-extraction rules + HTTPS-only network config
- [ ] `FLAG_SECURE` set in `MainActivity.onCreate` (not the manifest — it must survive the Android 12+
      apply recreate) and **only when `isPlayInstall()`**, which fails CLOSED on an unresolvable
      installer. The Play build blocks screenshots + recording; debug/sideloaded APKs stay visible so
      listing screenshots still work. `release-flag-secure-guard.js` denies any `.aab` that loses it
- [ ] No secrets in repo or APK — dart-defines only; `aapt dump badging` sanity when in doubt
- [ ] Worker vitest suite + `flutter test` green; `tsc --noEmit` clean; worker deployed
