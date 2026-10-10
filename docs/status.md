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
- Chips derive from the items, ordered by `category_order.statuses`; row order is the catalog's
  `feed_rank` (pins, then shares + saves), never re-derived on the phone.
- **The tab wears the feed's faces with its own words**: the loading card says status videos
  (`statusLoadingBody`), never wallpapers; empty is `FeedEmpty` with Browse all; a failure is
  `FeedError`; offline with NOTHING loaded is the offline card (`offlineStatusBody`), while clips
  already in hand keep playing from cache and Share/Save report offline themselves.
- A pull on the first card re-reads the catalog like the wallpaper reel's; `refresh()` keeps the
  clips on screen through the fetch and after a failure — only a reel with nothing shows loading.
- **A cold `/s/` link lands ON its clip.** On first data with All selected the screen seeds the pager
  and the pool with the target index before the first sync; opening card 0 first staged card 0 + 1
  against the linked clip (three transfers, 34–60 s on a slow 4G).

## The gate — same contract as the feed

- Await `entitlementProvider.future`; a failed read gates CLOSED, because `/media/signed-url` stays the
  authority. Not premium → `status_{share,save}_blocked_premium`, `JourneyStamps.noteGate` with
  `status_share`/`status_save`, then straight to `/premium?source=status_share|status_save`. A server
  403 `premium_required` routes to the paywall too and is never a crash record.
- **Every Share and Save calls `/media/signed-url`** (`kind: status`, `action: share|download` — the
  counters the order sums). A cached or prefetched clip skips only the download; offline with the
  bytes held is the one pass-through.

## Save

- **Byte for byte** (owner): the gallery file is the fetched clip, never a watermarked re-encode — the
  same preparing card as Share ([share.md](share.md) §Status clips), then the MediaStore write.
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

The status reel is its own pool of 2 (current + next), audible, hidden until the shell shows it; a tap
pauses or resumes, and is the only way out of a focus loss ([video-feed.md](video-feed.md) §Two reels).
Prefetch has its own store (`arulStatuses`, 20 objects, 2 ahead, 1 before the first paint, nothing under
Data Saver). Entering the tab stops the ringtone preview.

## Not wired yet (owner deferred)

- **Campaign pushes cannot target a status**: `push_payload` has no status `dest`, and builds that
  predate one open home on an unknown dest — target `push_devices.app_build` when it lands.
- Statuses are absent from the CMS category-transfer page and the push picker.
