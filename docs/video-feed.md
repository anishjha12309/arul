# The live-video feed — decoder budget and the reveal

Read before touching `android/**/feedvideo/**`, `lib/features/wallpapers/data/**` or
`video_preload_controller.dart`. Encoding rules and the dimension law:
[media-conventions.md](media-conventions.md). Card geometry: [browse.md](browse.md).

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
  Attempt and degrade; the try IS the probe.
- **Leaving the Wallpapers tab PAUSES at once and frees the decoders only after a grace period**
  (`releaseDecodersOnLeave`). Emptying the pool costs three `MediaCodec` instantiations to rebuild:
  measured on a Nothing A001 at **430 ms with no frame on the video surface**, and **10.4% of frames
  over 33 ms** across a tab-switch window against 3.9% idle. The pause is what stops audio and decode
  behind the ringtone list, and it is free; only the freeing is worth deferring. The other three
  release paths stay IMMEDIATE and must: the apply flow AWAITS one so the OS finds decoders free,
  backgrounding hands them to the OEM chooser, and `detach()` is a teardown.

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

## The reveal — why an undecoded live card looks static

Every card paints the `thumbs/` poster FIRST and keeps it mounted UNDER the texture; the texture
fades in only on `onRenderedFirstFrame`. There is no shimmer and no spinner on either layer, so a
live card that has not decoded yet is pixel-identical to a static one. That is deliberate: it means
"nothing is moving" is normally cold-cache latency, not a broken pipeline — **check the pool, not the
catalog.**

The one thing that does distinguish them is `LiveMark`, and it is static by design
([browse.md](browse.md) §The live mark).

Poster, full image and video texture must all share `ViewerMedia.cropAlignment`, or the frame jumps
on fade-in.

## Audio is decided at CREATE, not per open

`create(audio:)` picks the `AudioAttributes` and focus handling once, so a player built muted never
takes audio focus — raising its volume later changes focus behaviour not at all. Everything except
the paywall's onboarding clip stays `audio: false`: a preview that took focus would pause the user's
music while they browsed. The clip's URL is the one thing `Log.i("audible open")` prints, which
matters because the language cuts are the same footage and a screenshot cannot tell them apart.

## Noise to ignore

`BLASTBufferQueue … max frames` while the feed idles is benign compositor noise. Do not chase it.
