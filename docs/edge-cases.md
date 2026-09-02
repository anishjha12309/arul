# Edge Cases — the regression-contract index

Permanent regression contracts: each line is a bug someone already paid for, and they bind regardless
of UI design. Walk them on-device before cutting a release; **boxes stay unticked on purpose** —
unticked means "not re-checked for the release you are cutting now". Each section's reasoning lives
in the `docs/` file of the same name; this file carries the rule and nothing else.

## Video feed
- [ ] Live MP4s exactly 1024×1824 (w%128==0, h%32==0, inside the 1088×1920 hw cap)
- [ ] ExoPlayer pool REUSES players — `setMediaItem` swap, never dispose+recreate
- [ ] ONE process-global EventChannel hub; a second listener silently steals the sink
- [ ] Software-decoder fallback → pool demoted 3→2, **floor 2**; only a real codec error demotes to 1
- [ ] Decoder capability APIs untrusted — attempt and degrade, never query and assume
- [ ] Poster paints FIRST and stays mounted under the texture, which reveals on `onRenderedFirstFrame`, so an undecoded live card is pixel-identical to a static one; poster, image and texture share one `cropAlignment`
- [ ] Audio decided at CREATE, not per open; all but the paywall clip stays `audio: false`

## Wallpaper apply
- [ ] Static apply hands the OS a bitmap ALREADY centre-cropped to the display aspect; never `visibleCropHint=null` on the raw file
- [ ] Android 12+ recreate survived: `configChanges` has `uiMode|colorMode`, the launch theme is dark in `values/` and `values-night/`, and apply must NOT cold-restart
- [ ] Live apply downloads the MP4 first; the decoder is released only after that, awaited before the native call
- [ ] EVERY live apply opens the system chooser; the notifier finishes IDLE and never claims success
- [ ] `SCALE_TO_FIT_WITH_CROPPING` set in `VideoRenderer.initialize()`, never from display metrics
- [ ] ONE engine on ONE record — home and lock cannot hold different live videos
- [ ] The static fallback fires on EXACTLY TWO signals — no live-wallpaper feature, or both chooser launches throwing — never anything else
- [ ] OEM live-wallpaper restrictions caught → a localized error, never a crash

## Auth
- [ ] Sign-in auto-launches a Google surface on the first frame, never a silent check
- [ ] SHEET FIRST, picker second; a pill tap skips the sheet; the `sheetFirst` kill switch stays a BUILD const
- [ ] EXACTLY ONE visible Google surface per attempt; the picker follows only a sheet that drew nothing or could not COMPLETE. A DISMISSED sheet stops it — no picker, no auto-relaunch
- [ ] Every ID token carries the per-process nonce and the Worker checks the PAIR, both-absent accepted so fielded builds keep working. Never log or track it
- [ ] Sign-out and delete clear Credential Manager state, best-effort, after the local clear
- [ ] Sign-in bg video: a shared ref-counted player with a 2 s dispose grace
- [ ] Failures classified by typed `code` only; EVERY failure return goes through `_googleFailure`; the 30 s stall clock counts FOREGROUND time only
- [ ] `POST /auth/login` retries connectivity-class failures only, inside the stall budget; never a server RESPONSE
- [ ] `login_cancelled` is a MIXED bucket — split on message text first, timing second

## Premium / payments
- [ ] `ensurePremium()` AWAITS `entitlementProvider.future` — a loading snapshot must never bounce a premium user
- [ ] Entitlement live-read from Neon on every gated action; never cached in the JWT
- [ ] `cancelled` keeps premium to period end with NO grace; `trialing`/`active` get 6 h; `pending` with a live period counts; `paused`/`expired` none; `reward_premium_until` ORed in
- [ ] A failed/abandoned setup RESTORES to `cancelled` while the period lives, never `expired`; the resurrect matches `('expired','cancelled')`
- [ ] Unpause REARMS `next_debit_at`, scoped to `paused` rows; `/payments/status` heals both lost pause and lost unpause
- [ ] The app reads the `premium` flag from `GET /me` and NEVER re-derives the rule from the row
- [ ] One trial ever: `trial_end` consumed-marker + a delete-account HMAC tombstone (secret NEVER rotates)
- [ ] Endpoint contracts hold — SDK order token, the cancel path, 409 `setup_in_progress`, webhook dedupe
- [ ] Re-applying or re-sharing a CACHED wallpaper still calls `/media/signed-url`; offline with bytes on disk is the one pass-through
- [ ] A blocked action tracks `${action}_blocked_premium` and routes STRAIGHT to `/premium?source=` — no nudge, sheet or interstitial
- [ ] The confirmation poll TOLERATES network failure and OUTLIVES the paywall; never-reached says confirmation is late, not the refund line
- [ ] Delete account: revoke → tombstone → cascade → refresh-jti denylist

## Browse
- [ ] CATEGORY chips only (All + 6), static/live interleaved; an unknown category falls into All and an empty one shows a localized empty state
- [ ] Order is ONE SQL clause numbered into `feed_rank`, sorted by the shipped comparator on EVERY chip; the last tie breaks on a unique key
- [ ] No pins, no decayed score; `apply_score`/`set_score`/`scored_at` stay unread and no second sort key joins the counter
- [ ] Apply-restore and deep links resolve their index through the SERVED list
- [ ] Reel card geometry lives ONLY in `feed_card_geometry.dart`, pinned by its test — read the solved size, never `cardAspect`
- [ ] The floor splits `headroom`/`underhang` around the reel; screen-anchored things offset by `underhang + peek + gap`. 1.78 is a BOUNDARY, not a dial
- [ ] Live cards marked by `LiveMark` ONLY: static, 22 dp inset, no shadow, no text
- [ ] The two over-media glass objects share a rim but NOT a fill; never unify them
- [ ] Skeleton and reel read the SAME geometry

## Ringtones
- [ ] Own six categories (five deities + `others`, no `temples`); `deity` is display only
- [ ] The tab renders nothing until the WHOLE catalog drains — pages drain 4-wide, never serially
- [ ] Set writes ONE tone to EVERY SIM row; keys ENUMERATED off the provider; each write wrapped alone
- [ ] `canWrite()` false → straight to `ACTION_MANAGE_WRITE_SETTINGS`, PARKED for the next resume, no explainer
- [ ] Below API 29 the tone is copied to the public Ringtones dir on the EXTERNAL volume
- [ ] Picker name = the CATALOG TITLE, not the filename; `mime` rides along
- [ ] Stale-row cleanup must NEVER abort the set
- [ ] ONE shared preview player; every now-playing affordance derives from ONE `currentId`
- [ ] Row art BUNDLED per deity over an id-hashed ground, ≥8 grounds per category; `cover_key` stays null
- [ ] Preview is FREE; only Set gates
- [ ] Set has a re-entrancy guard

## Upload (wallpaper + ringtone)
- [ ] confirm-upload takes kind `wallpaper` or `ringtone` ONLY and QCs bytes against THAT kind's role — a constant role rejects every ringtone. Idempotent via unique `file_key` upsert; keys forced under `user/<sub>/`
- [ ] A category is required for BOTH kinds and approval carries it onto the row; `ringtones.category` is NOT NULL, so the CMS vets it BEFORE copying
- [ ] The kinds do NOT share a category list — the wrong set files a row under a chip that tab never renders. A submitted `deity` stays NULL
- [ ] Moderation approve NEVER ships a dimension-violating video as-is

## Notifications, share and deep links
- [ ] Notifications are local only; there is no push channel and no screen may promise one
- [ ] Festival dates are DATA — a table that runs out means SKIP, never extrapolate
- [ ] `keep.xml` stops R8 stripping the icons; breaks release builds ONLY
- [ ] QA tools gate on `kDebugMode` OR not `isPlayInstall`, so a sideloaded release keeps them
- [ ] EXACTLY ONE link leaves per share, owned by the caption, trailing
- [ ] WhatsApp-first by a DIFFERENT mechanism per path — the text-only link silently drops the file
- [ ] A share link carries `ilang=`, never `lang=`; the live watermark needs API 31, below which the share ships clean rather than crashing
- [ ] Intent-filters never merged across schemes; `flutter_deeplinking_enabled` stays true
- [ ] ONE level of encoding on `referrer`; the Worker's language normalisation matches the app's
- [ ] The link's `lang` ALWAYS wins over the device default and the user's Settings pick
- [ ] Typed takes: `consumeWallpaper()` never eats a pending ringtone, or the reverse

## Catalog / storage
- [ ] `version.json` edge-cacheable (`max-age=30` + SWR), pages `max-age=86400` + `?v=`; stale = rebuild, NEVER purge
- [ ] A zero-row scope still writes a valid empty `all_1.json` — a 404 means the build FAILED, never "no content"
- [ ] Orphaned pages deleted each rebuild; the hourly sweep runs only after a fully-successful rebuild that touched a scope, and the daily 21:30 UTC pass is the backstop
- [ ] Both sweep failsafes hold — a zero referenced-key set ABORTS that prefix, and the blast-radius cap refuses an oversized delete
- [ ] Hyperdrive query caching OFF (it caused ~60 s staleness)
- [ ] Bucket/KV/DB are exclusively Arul's — sharing means mutual media deletion. R2 objects are public BY DESIGN; never add a "private" one

## App-wide
- [ ] Privacy / Terms / Refund open the IN-APP reader (`/policy/:doc`), never `launchUrl` — leaving for Chrome is a store rejection. Navigation is fenced to the policy host (all else, `mailto:` included, goes to the OS), the site's navbar and footer are hidden, and the page is held back until they are. The document stays REMOTE, so this surface needs a real offline state
- [ ] Loading / empty / error state on every async surface, localized in all 6 locales — EXCEPT the paywall (English by decision) and purchase/auth error strings
- [ ] Worker error envelope `{error:{code,message}}` handled; offline → a retry affordance
- [ ] Analytics only via `AnalyticsService`; ★ mirrors to GA4 `login`/`begin_checkout` + Meta — **no `purchase` anywhere**
- [ ] `allowBackup=false`, data-extraction rules, HTTPS-only network config
- [ ] `FLAG_SECURE` set in `MainActivity.onCreate` (not the manifest — it must survive the apply recreate) **only when `isPlayInstall()`**, which fails CLOSED; a guard denies any `.aab` that loses it
- [ ] No secrets in repo or APK; dart-defines only
- [ ] Worker vitest + `flutter test` green, `tsc --noEmit` clean, worker deployed
