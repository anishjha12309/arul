# Status tab — devotional clips with music, Save and WhatsApp

Read before touching `lib/features/status/**`, `android/**/status/**` or the status half of
`DirectShareChannel.kt`. Clip spec and poster: [status-clips.md](status-clips.md) · the shared reel,
decoders and audio: [video-feed.md](video-feed.md) · the share chain: [share.md](share.md) §Status clips
· links: [deep-links.md](deep-links.md) · contracts: [edge-cases-reel.md](edge-cases-reel.md).

## A fixed tab, no remote switch

- **Status is always in the dock, like Wallpapers and Ringtones** (owner). A dock gated on the config
  grows its third tab a moment after the first paint on every launch: the config has no disk copy and
  lands late. Hiding the tab takes a release.
- **Older builds still gate it on `app_config.feature_flags.status_tab`** (on only for a literal
  `true`; anything else is their two-tab app), so keep it `true` while they are in the field. The CMS
  flag save bumps `content_version`, which re-downloads every build's catalogs; so does every status
  upload — put a library up as ONE batch.

## Catalog and order

- **Drained on the first open of the tab**, straight from the CDN with no disk copy, never in the
  pre-first-paint drain, so a phone that never opens the tab never pays a byte for it. A missing page 1
  is the error state with retry: every status publish writes it, so a user meeting it is an operational
  fault.
- Chips derive from the items, ordered by `category_order.statuses` bar the app language's lead
  (§Language); row order is the catalog's `feed_rank`, never re-derived on the phone (§Order).

## Order — a weighted shuffle, redrawn every hour (owner)

- **No pins and no fixed order.** `build-catalog` draws a weighted random order (`weightedShuffle`,
  `statusWeight` in `workers/src/lib/feed-score.ts`) and numbers it into `feed_rank`; the `feed_rank`
  COLUMN is ignored for statuses and the CMS no longer offers a status pin. Same order for every phone
  until the next draw; a category chip is All filtered, as on the other tabs.
- **Weight = 1 + 3 × uses + 3 × fresh.** Uses = `share_count + download_count`, log-scaled against the
  busiest clip so one viral clip cannot own slot 1. Fresh fades 1 → 0 over 7 days from the later of
  `published_at` and `renewed_at` (a CMS Renew restarts it). The floor of 1 keeps every clip in reach.
- **Redrawn on every build, including the hourly no-change run**, reported as `{ reshuffled }` so the
  canonical sweep still waits for a real change. Each draw reads the counters live from Neon.
- **ONE page, short-cached** ([caching.md](caching.md)): the edge caches pages apart, so two pages could
  join two draws and show a clip twice. The app drains it once per process, so a new draw lands on the
  next cold start or pull-to-refresh, never mid-scroll.
- **The tab wears the feed's faces with its own words**: the loading card says status videos
  (`statusLoadingBody`), never wallpapers; empty is `FeedEmpty` with Browse all; a failure is
  `FeedError`; offline with NOTHING loaded is the offline card (`offlineStatusBody`), while clips
  already in hand keep playing from cache and Share/Save report offline themselves.
- A pull on the first card re-reads the catalog like the wallpaper reel's; `refresh()` keeps the
  clips on screen through the fetch and after a failure — only a reel with nothing shows loading.
- **A cold `/s/` link lands ON its clip.** On first data with All selected the screen seeds the pager
  and the pool with the target index before the first sync; opening card 0 first staged card 0 + 1
  against the linked clip (three transfers, 34–60 s on a slow 4G).

## Language — asked once, it leads (owner)

- **The first Status visit asks the language ONCE** and makes it the APP language (`setLocale`, `pick`).
  `arul_status_lang_asked` is set before the sheet opens, so a dismissal counts; a pending cold `/s/`
  link skips the ask (flag unset): the link answers first.
- **Categories are named after languages** (`statusSlugForLanguage`), so the app language's category is
  the first chip, ahead of All, and opens the reel when the catalog has it. The selection is null until
  a pick: read `activeStatusCategoryProvider`. A pending status link keeps All and pins it once consumed.

## The gate — same contract as the feed

- Await `entitlementProvider.future`; a failed read gates CLOSED, because `/media/signed-url` stays the
  authority. Not premium → `status_{share,save}_blocked_premium`, `JourneyStamps.noteGate` with
  `status_share`/`status_save`, then straight to `/premium?source=status_share|status_save`. A server
  403 `premium_required` routes to the paywall too and is never a crash record.
- **Every Share and Save calls `/media/signed-url`** (`kind: status`, `action: share|download` — the
  counters the order sums, plus one `status_actions` row per grant for the CMS's per-person ranking). A cached or prefetched clip skips only the download; offline with the
  bytes held is the one pass-through.

## Save

- **Save matches what Share sends** (owner): the user's photo and name burnt in when they are on and the
  phone is API 31+ (§Your photo and name), else the fetched clip byte for byte; never a trace watermark.
  The same preparing card as Share ([share.md](share.md) §Status clips), then the MediaStore write.
- A fresh MediaStore entry per save in `Movies/Arul`: `IS_PENDING=1` → copy → `0`, off the main thread
  (a whole-file copy through the provider takes seconds on a budget phone); a failed copy deletes the
  row. API 29+ needs no permission — never request `READ_MEDIA_*`.
- **Android ≤9 needs `WRITE_EXTERNAL_STORAGE`** (manifest `maxSdkVersion=28`), asked on the FIRST save,
  never at launch, under request code **5002** with its own parked call (5001 is the ringtone prompt; a
  second tap while the prompt is up answers `busy`). A denial is the localized permission line plus
  `status_save_failed {reason: permission_denied}`. Below API 29 the public file is written, then
  scanned.
- `MainActivity` request codes: 5001 ringtone storage · 5002 status storage · 5101 the WhatsApp
  composer's result, dropped before the plugin chain because nobody reads it.

## Player and prefetch

- **One status per page, at its clip's own shape, whole** (owner). The
  catalog carries each clip's `width`/`height` (`StatusVideo.aspect`; a row without them is the old
  1024×1824); the page is the reel above the verb bar, 12 dp either side and 4 dp above and below.
  `FeedCardGeometry.contain` fits the clip into it, centred — a 2:3 clip is shorter, a 9:16 one
  narrower. `BoxFit.fill` is then lossless.
  No peek of the next clip, no card geometry, no end mark. Never cover (it cut the title first on short
  phones) and never a blur or a bar beside the picture (a stretched-poster blur read as a blurred clip).
  `tools/status-reencode.mjs` cut the first library's baked fill bands ([status-clips.md](status-clips.md)).
- **The chip row stays through every swipe** (owner): a fold that gave the page its ~60 dp read as
  the categories vanishing. The page is what is left under the chips.
- **The verbs sit in ONE fixed 56 dp bar under the reel, never over the clip** (owner):
  Photo · Save as quiet pills, the green WhatsApp pill filling the rest; it acts on the clip in view.
  `_BarFit` picks, for the whole row: translations with glyphs, else an overflowing label in plain
  English (owner), else the quiet pills without glyphs, else tighter padding; a word is never cut.

The status reel is its own pool of 2 (current + next), audible, hidden until the shell shows it; a tap
pauses or resumes, and is the only way out of a focus loss ([video-feed.md](video-feed.md) §Two reels).
Prefetch has its own store (`arulStatuses`, 20 objects, 2 ahead, 1 before the first paint, nothing under
Data Saver). Entering the tab stops the ringtone preview.

## Your photo and name (owner)

- **Adding and previewing are free; Share and Save stay premium** (§The gate): the burn-in runs after
  the gate and the fetch.
- **The photo never leaves the phone**: app-support `status_photo.jpg`, a 640 px centre-cropped square,
  never the pick cache (wiped every engine start). Native `squarePhoto` uses `ImageDecoder` (HEIC, EXIF
  rotation). The name is the account's display name (`updateDisplayName` → `POST /me/profile`),
  one name with Settings. Switches: `arul_status_show_photo`, `arul_status_show_name`, default on.
- **ONE painter, `status_overlay.dart`, draws the card preview AND the export PNG**, every size a
  fraction of the clip, so the two agree to the pixel. The photo goes in the clip's `photo_slot`
  ([status-clips.md](status-clips.md)), clipped to its shape (a `clipPath`: Impeller drops a
  saveLayer mask); no slot → a gold-ringed avatar in the clip's corner, never on the band (owner).
- **The name lives in a band UNDER the clip, never on it** (owner: 346 of 400 slots reach the bottom
  7.5%, where a strip cut photos and captions). `#14090C`, gold hairline, `bandPxFor` ≈ 5.6% of the
  clip in 32 px steps (1152 → 64); card = clip + band.
- **`_personalise` runs on Share AND Save**: nothing switched on, or API < 31 → the source untouched.
  Else free the status reel's decoders (the export needs a hw decoder AND encoder), render the PNG at
  the clip + band (Media3 places it 1:1), then `overlayVideo`, which grows the frame (Presentation
  SCALE_TO_FIT + a MatrixTransformation lift) so the band sits under the picture: 768×1152 → 768×1216.
  A failed export fails the action. The events gain `with_photo`, `with_name`; `watermarked` stays false.
- **Below API 31 the feature is absent, not degraded**: Media3's Transformer kills the process there
  ([known-issues.md](known-issues.md)). No preview on the card, Photo opens a sheet that says so, and
  clips go out as before.

## Not wired yet (owner deferred)

- **Campaign pushes cannot target a status**: `push_payload` has no status `dest`, and builds that
  predate one open home on an unknown dest — target `push_devices.app_build` when it lands.
- Statuses are absent from the CMS category-transfer page and the push picker.
