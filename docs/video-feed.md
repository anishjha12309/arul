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
