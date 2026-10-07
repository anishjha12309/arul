# Edge cases — the regression-contract index

One line per paid-for bug, binding whatever the UI; walk them on device before a release. Reasoning:
each heading's docs.

**Video reels and the Status tab: [edge-cases-reel.md](edge-cases-reel.md)** — walk both files.

## Wallpaper apply — [wallpaper-apply.md](wallpaper-apply.md)
- [ ] Static apply hands the OS a bitmap already centre-cropped to the display aspect
- [ ] Android 12+ recreate survived: `configChanges` has `uiMode|colorMode`
- [ ] Live apply downloads first (`.part` kept), then frees the decoder, awaited before the native call
- [ ] EVERY live apply opens the chooser; the notifier finishes IDLE and never claims success
- [ ] `SCALE_TO_FIT_WITH_CROPPING` set in `VideoRenderer.initialize()`, never from display metrics
- [ ] A rebuilt engine decoder resumes at the source's last position, never at 0
- [ ] The engine player takes the raw `Surface`, on main; ONE engine on ONE record
- [ ] The engine's private copy is adopted on the IO thread, never on an engine callback
- [ ] Static fallback on EXACTLY two signals: no live-wallpaper feature, or both chooser launches throw
- [ ] OEM live-wallpaper restrictions → a localized error, not a crash

## Auth — [auth.md](auth.md), [sign-in-wall.md](sign-in-wall.md)
- [ ] A Google surface auto-launches on the first frame; no network at launch HOLDS it
- [ ] Sheet first, picker second; a pill tap skips the sheet
- [ ] At most TWO surfaces per attempt; a dismissed sheet escalates ONCE to the button flow
- [ ] `am crash` with the sheet in front, then the icon → a fresh Arul on API 31+ (`main_launch_mode`)
- [ ] A stripped picker or an add-account return reopens the PICKER once; `clearTaskOnLaunch` stays
- [ ] Below the GMS floor, Google's own update dialog
- [ ] Per-process nonce; the Worker checks the PAIR (both absent is accepted)
- [ ] Failures classified by typed `code`, all through `_googleFailure`
- [ ] The 30 s stall counts FOREGROUND time, read every 250 ms; an empty resume abandons after grace
- [ ] A return re-arms the sheet once (`sheet_return`); a reconnect once per failure, twice per stretch
- [ ] Offline: a tap parks (`button_after_offline`); a wall mounted offline and a link back while paused still reconnect
- [ ] `POST /auth/login` retries connectivity failures only, inside the stall budget
- [ ] The wall shows ONE retry line; the pill is its only tappable thing; no box while an attempt runs
- [ ] Sign-out/delete clear Credential Manager state after the local clear and reset analytics identity first
- [ ] A dead refresh signs the UI out; a Keystore refusal moves tokens to app-private storage
- [ ] A launch clip downloads only after the poster AND Google's surface; never on Data Saver or a poster phone

## Premium / payments — [architecture.md](architecture.md), [phonepe.md](phonepe.md), [checkout.md](checkout.md)
- [ ] `ensurePremium()` AWAITS `entitlementProvider.future`; the app reads `premium` from `GET /me`
- [ ] Entitlement live-read on every gated action — `/media/signed-url` even for cached bytes
- [ ] `cancelled` keeps premium to period end, no grace; `trialing`/`active` get 6 h
- [ ] A re-subscribe PARKS the live mandate; a failed setup RESTORES it; cancel and delete revoke both
- [ ] `/payments/status` heals a missed COMPLETED redemption and a lost pause/unpause
- [ ] Unpause REARMS `next_debit_at`, scoped to `paused` rows
- [ ] One trial ever: `trial_end` marker + delete-account HMAC tombstone (secret NEVER rotates)
- [ ] ₹99 offer: [cancel-offer.md](cancel-offer.md) §Contracts; stranded claims and settles heal hourly
- [ ] 409 `setup_in_progress` ≠ `already_subscribed`; the client retry delays sum to the claim window
- [ ] Picker = `MANDATE_APPS` resolving a mandate-shaped probe; no app → the CTA sells the QR
- [ ] An OPEN order on return is RESUMABLE; only another app or the deadline abandons, silently
- [ ] The confirmation poll tolerates network loss and outlives the paywall
- [ ] Trial marker set AT the UPI handoff; the return page never on the ₹199 sell
- [ ] `trial_started` never re-fires on a reinstall or 2nd phone; never without `value`
- [ ] A blocked action routes straight to `/premium?source=`, nothing in between
- [ ] The Manage row only for premium with a `trialing`/`active`/`cancelled` row
- [ ] Delete account: revoke → tombstone → cascade → refresh-jti denylist

## Browse — [browse.md](browse.md), [feed-card.md](feed-card.md)
- [ ] Category chips only, static/live interleaved; an unknown category falls into All
- [ ] Order is ONE SQL clause numbered into `feed_rank`; pins are the only hand tier; last tie on `id`
- [ ] No decayed score; `apply_score`/`set_score`/`scored_at` stay unread
- [ ] New has its OWN order: renewed → debuts → filler to 20 by uses; never by pin
- [ ] Restore and deep links index the SERVED list; restore saves the chip the user was on
- [ ] Card geometry only in `feed_card_geometry.dart`; read the solved size, never `cardAspect`
- [ ] `LiveMark` only: static, no shadow, no text; the two glass objects never share a fill

## Ringtones — [ringtones.md](ringtones.md)
- [ ] Own categories (five deities, no `temples`, `others` tolerated only); `deity` is display only
- [ ] The tab renders after the WHOLE catalog drains, 4-wide
- [ ] Set writes ONE tone to EVERY SIM row; keys ENUMERATED; each write wrapped alone
- [ ] `canWrite()` false → straight to `ACTION_MANAGE_WRITE_SETTINGS`, PARKED for the next resume
- [ ] Below API 29 the tone goes to the public Ringtones dir on the EXTERNAL volume
- [ ] Picker name = the catalog title; `mime` rides along; stale-row cleanup never aborts the set
- [ ] ONE preview player, ONE `currentId`; preview is free, only Set gates
- [ ] Row art bundled per deity over an id-hashed ground (≥8 per category); `cover_key` stays null

## Upload — [architecture.md](architecture.md) §Uploads
- [ ] confirm-upload QCs bytes against the submitted KIND's role; idempotent on unique `file_key`
- [ ] A category is required for both kinds, from that kind's OWN list
- [ ] Moderation never ships an off-spec video as-is
- [ ] ONE picker per app (guard the call); no permission, no `resolveActivity` pre-flight

## Push — [push.md](push.md), [push-registry.md](push-registry.md), [notifications.md](notifications.md)
- [ ] Two channels, created at launch; campaigns only through the CMS; retired reminders cleared
- [ ] The campaign channel copies a blocked or lowered `arul_updates_v1` once, and is never created natively
- [ ] Every campaign to a build >= `HEADSUP_MIN_BUILD` is data-only; a premium campaign stays PRIVATE on the lock screen
- [ ] An Android 13+ phone that never signed in is in no audience; the count and `left_out` say how many
- [ ] A campaign's `push_campaign_langs` rows sum to its sent/failed/gone; a replayed tap adds no open
- [ ] Permission asked once, on the first feed frame after sign-in — never on the wall
- [ ] No Dart background handler; an unreadable payload opens the app
- [ ] BOTH tap paths deliver: killed and backgrounded
- [ ] A tap lands even under `/premium`; a cold tap waits for the splash's auth decision (`PushTapRouter`)
- [ ] `keep.xml` stops R8 stripping the notification icons (release builds only)

## Share — [share.md](share.md)
- [ ] EXACTLY ONE link per share, owned by the caption, trailing; it carries `ilang=`, never `lang=`
- [ ] WhatsApp-first by a DIFFERENT mechanism per path — the text scheme drops the file
- [ ] The live watermark needs API 31; below it the share ships clean, never crashes
- [ ] The status composer carries NO link; its chat/sheet fallback carries exactly one `/s/` link

## Deep links — [deep-links.md](deep-links.md), [deferred-links.md](deferred-links.md)
- [ ] Intent-filters never merged across schemes; `flutter_deeplinking_enabled` stays true
- [ ] ONE level of encoding on `referrer`; the Worker's language normalisation matches the app's
- [ ] Native checks a deferred link's HOST only; Dart decides path and query
- [ ] The link's `lang` beats a Settings pick, the region and the phone
- [ ] The region is asked once per FRESH install, never picks the language; an older build's stored region language stays
- [ ] Typed takes: `consumeWallpaper()` never eats a pending ringtone, or the reverse

## Catalog / storage — [cron.md](cron.md), [caching.md](caching.md)
- [ ] Pages `max-age=86400` + `?v=`; stale = rebuild with a version bump, never a purge
- [ ] A zero-row scope or a missing `statuses` table writes a valid empty `all_1.json`
- [ ] Sweep: zero referenced keys aborts a prefix (empty folder: skip); the blast-radius cap refuses an
      oversized delete; status posters referenced pre-upload
- [ ] Old builds' pages and chip keys unchanged; no status chip in the wallpaper key
- [ ] Hyperdrive query caching OFF; bucket, KV and DB Arul's alone; R2 objects public by design

## Review prompt — [review-prompt.md](review-prompt.md)
- [ ] Play's sheet only on a LATER cold open than the arming success, nothing above the feed; ≥2
      successes, the first 3+ days old; a skip keeps the arm; ≤1 ask per rolling 120 days; no pre-prompt

## In-app update — [app-update.md](app-update.md)
- [ ] Never over the splash, the wall, a sign-in attempt, `/premium` or a loading apply/share/set;
      a FLEXIBLE download never resumes as IMMEDIATE; the update beats the review sheet to the launch

## App-wide
- [ ] Policy pages: the IN-APP reader (`/policy/:doc`), never `launchUrl`; host-fenced, chrome hidden
      before reveal; offline = our error + Retry, never cleared by `onPageFinished` (fires on Android's
      error page too)
- [ ] Loading/empty/error on every async surface in 6 locales; failure copy per KIND, never the Worker's `message`
- [ ] A system Back never escapes go_router's `popRoute` ([known-issues.md](known-issues.md))
- [ ] No `purchase` event anywhere ([analytics-events.md](analytics-events.md))
- [ ] `allowBackup=false`, data-extraction rules, HTTPS-only
- [ ] `FLAG_SECURE` set in `MainActivity.onCreate` only when `isPlayInstall()`, fail-CLOSED
