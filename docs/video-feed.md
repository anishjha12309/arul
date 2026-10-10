# The video reels — decoder budget, visibility and the reveal

Read before touching `android/**/feedvideo/**`, `lib/app/widgets/reel/**` or
`lib/features/wallpapers/data/**`. The Status tab's own contracts: [status.md](status.md). Encoding rules and the dimension law:
[media-conventions.md](media-conventions.md). Card geometry and the live mark: [feed-card.md](feed-card.md).

Budget SoCs fit roughly two concurrent 1080p hardware decoder sessions. Everything here exists
because exceeding that fails SILENTLY — a software fallback, a green edge strip, or a black card —
never with an error.

## The pool

- **Players are REUSED — `setMediaItem` swap, never dispose+recreate per swipe.** Teardown lives in
  exactly one place; `open()` only swaps the media item and bumps the open id.
- **ONE process-global EventChannel hub.** The native side holds a single `eventSink` field, so a
  second Dart listener silently steals it and the first stops receiving frames.
- **Detect the silent software-decoder fallback** (`onVideoDecoderInitialized`) and demote the pool
  budget 3 → 2, with a **floor of 2**. Only a real codec error may demote to 1.
- **Never query decoder capability and assume.** `getMaxSupportedInstances` lies in both directions.
  Attempt and degrade; the try IS the probe. Keep the diagnostic query OFF the main thread:
  `MediaCodecList`'s first enumeration is a binder round-trip to the codec service that some phones
  answer in seconds, and on main it ANR'd the first feed frame.
- **Leaving a reel — a tab switch or a full screen pushed over it — PAUSES at once and frees the
  decoders only after a 3 s grace** (`releaseDecodersOnLeave`). Emptying the pool costs three `MediaCodec` instantiations to rebuild —
  hundreds of ms with no frame on the video surface and a burst of janky frames on every tab switch.
  The pause is what stops audio and decode
  behind the ringtone list, and it is free; only the freeing is worth deferring. The other three
  release paths stay IMMEDIATE and must: the apply flow AWAITS one so the OS finds decoders free,
  backgrounding hands them to the OEM chooser, and `detach()` is a teardown.

## Two reels, one device

`VideoPreloadController<T extends ReelItem>` drives both the feed (pool 3: previous + current + next)
and the status reel (pool 2: current + next, audible). **The decoder budget is static and shared** —
one device, one set of hardware sessions — so a demotion in either reel binds both.

- **Two pools never decode at once.** Entering a reel releases the OTHER reel IN FULL (awaited) before
  claiming, with no grace: 3 + 2 players against ~2 hardware sessions is the silent-failure class.
  That includes a hop through Ringtones — the left reel is still inside its grace, and the A001 read
  5 video decoders for the whole 3 s before this. A swap overtaken during its await never reclaims
  (`_swapSeq`). A leave to Ringtones keeps the grace. A hidden reel's `reclaimDecoders` is a no-op,
  or a catalog refresh under another tab cancels the grace and holds the pool with no timer.
- **`visible` gates every `play()`** — reconcile, assignment and the `resumed` handler — and a hidden
  reel claims no decoders: an audible pool playing hidden is sound from nowhere. The shell owns the
  flag: tab switches, and `RouteAware` on the root navigator (`shellRouteObserver`) for any PAGE route
  pushed over it (Settings, paywall, upload, policy) — pause now, release after the grace, restore on
  pop. A dialog or sheet is not a page route and pauses nothing. A cold start straight onto Status (a
  push tap) runs no switch, so the shell sets visibility in its first post-frame — as does a REBUILT
  shell on Wallpapers (sign-out and back, a paywall `go`): the app-scoped feed kept the hidden flag
  from being covered, and every live card stayed a poster.
- **Focus loss latches.** Native reports `focusLost` and the reel controller holds the clip until a
  TAP — no reconcile, resume or swipe restarts it over the call or music that took the speaker. A
  user's tap-pause clears on a swipe; the focus latch only on a tap.
- **The plugin owns ONE focus request for every audible player** (`handleAudioFocus` is false on each
  ExoPlayer). Per-player Media3 focus made every swipe's new clip take focus from the pool's previous
  player as a PERMANENT loss, which latched the reel paused on the phone. Only another app's
  `LOSS`/`LOSS_TRANSIENT`, or headphones out (Media3's noisy handling), reaches Dart; a refused
  request (Android 15+, app not on top) never plays.
- **A hot restart resets Dart, not the plugin**, so a status clip kept its sound with no handle left
  to pause it. The first `create` of a new isolate calls native `disposeAll` to release orphans.

## The feed opens FILES. A CDN stream is a failure path, never the plan

`_setupAndOpen` awaits `ensureCached` and opens the local path; the poster covers the wait, and the
http(s) URL is reached only when that transfer failed. Streaming looked cheaper — a first frame after
250 ms instead of a whole download — and is unusable here for three reasons that compound:

- Clips run **1.3–9.8 Mbit/s** (the ceiling is 15 MB, not a bitrate), so any pipe under the clip's
  own rate under-runs within a second.
- **`REPEAT_MODE_ONE` re-reads the media from zero on every lap** — `DefaultLoadControl`'s back
  buffer is 0 — so a looping stream re-downloads the whole clip once per lap, for as long as the
  card is on screen, and never consults the copy the prefetcher has since written to disk. Parked on
  one card for three minutes: **310 MB streamed against 0.1 MB from a warm file.**
- The prefetcher is fetching the SAME url through `dart:io` at the same time. Two clients, two
  transfers, no sharing.

An under-run freezes the texture on the clip's opening frame, which IS the poster image — so the
card reads as "the poster came back, then the video returned", every lap. **A rebuffer is not what
hides a texture; only a re-`open()` is**, and the one that fires mid-play is `_onPlayerError`'s
non-decoder branch: it must leave an already-painted card alone, or a network blip restarts the clip
from zero in front of the user. The decoder-error retry and budget demotion are a different class and
stay as they are.

The current card jumps every queue (`ensureCached(priority:)`): while its bytes are landing, the two
window neighbours and the whole look-ahead queue hold. Without that a neighbour's clip painted seven
seconds before the card the user was looking at.

## The data window is the data-plan budget

`WallpaperPrefetchService` pulls upcoming MP4 BYTES to disk, no decoders, so depth never janks —
but a clip averages ~4.5 MB and the window reaches cards the user may never. **Keep the look-ahead
shallow (3; 2 until the first card paints).** At 15 the queue never drained while the user swiped:
the pipe ran flat out at ~5 MB/s for the whole scroll (505 MB in 90 s on a 3 GB Vivo), and bytes
tracked time spent scrolling, not cards reached. The 160 ms settle debounce already stops mid-fling
pages from enqueuing; the disk LRU (120 objects) stays deep so a cached cold start opens from files.
Encode size is not the lever — the 15 MB ceiling is quality-first by the owner's call.

**Status clips stage into their OWN store** (`arulStatuses`, 20 objects at ~8 MB; 2 ahead, 1 until the
first paint), so a reel of 10 MB clips never evicts live wallpapers from the feed's LRU.

**Under Android's Data Saver on a metered link, stage NOTHING ahead** (`DataSaver`, native
`isActiveNetworkMetered && RESTRICT_BACKGROUND_STATUS_ENABLED`): the visible card still loads, the
look-ahead and the return clip's speculative warm do not. Data Saver on Wi-Fi restricts nothing.

## The reveal — why an undecoded live card looks static

Every card paints the `thumbs/` poster FIRST and keeps it mounted UNDER the texture; the texture
fades in only on `onRenderedFirstFrame`, and a reassigned player's stale frame CUTS out (a fade
dissolved the last clip into the next card's poster on a chip switch). Until the poster lands the
card shows the loading card's sweep — ink on the ink frame left two buttons floating in a void — and
nothing else: no spinner on either layer, so a live card that has not decoded yet is pixel-identical
to a static one. "Nothing is moving" is cold-cache latency, not a broken pipeline — **check the pool,
not the catalog.**

The one thing that does distinguish them is `LiveMark`, and it is static by design
([feed-card.md](feed-card.md)).

Poster, full image and video texture must all share `ViewerMedia.cropAlignment`, or the frame jumps
on fade-in. Status cards share `Alignment.center` instead: a status is composed around its middle text
line, and the top bias showed a fill band above the clip while cutting its lower words.

## Audio is decided at CREATE, not per open

`create(audio:)` picks the `AudioAttributes` and focus handling once, so a player built muted never takes
audio focus — raising its volume later changes focus behaviour not at all. Only the paywall's ONE
player and the status pool are audible; every feed player stays `audio: false`, because a preview that took
focus would pause the user's music while they browsed. The onboarding clip and the return page's clip SHARE
the paywall player — the reel under `/premium` holds its decoders through the 3 s grace, so a second one
would break the budget. Hand it over by giving the other card `null`,
and take it back only after the return page's exit plus one frame: its card pauses the player as it
disposes, which silenced a clip handed back any earlier. The clip's URL is the one thing
`Log.i("audible open")` prints, which matters because the language cuts are the same footage and a
screenshot cannot tell them apart.

## Noise to ignore

`BLASTBufferQueue … max frames` while the feed idles is benign compositor noise. Do not chase it.
