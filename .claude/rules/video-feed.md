---
description: Decoder budget, player reuse and the poster-first reveal in the live feed.
paths:
  - "android/**/feedvideo/**"
  - "lib/features/wallpapers/data/**"
  - "lib/features/wallpapers/presentation/video_preload_controller.dart"
  - "lib/features/wallpapers/presentation/viewer_media.dart"
---

Budget SoCs fit about two concurrent 1080p hardware decoder sessions, and exceeding that fails
SILENTLY — a software fallback, a green edge strip, or a black card.

- **Live MP4s are exactly 1024×1824** — `width % 128 == 0`, `height % 32 == 0`, inside the 1088×1920
  hardware cap. Anything else hits the green-edge / software-decode bug class.
- **Players are REUSED**: `setMediaItem` swap, never dispose+recreate per swipe.
- **ONE process-global EventChannel hub** — the native side holds a single sink, so a second listener
  silently steals it.
- **Detect the software-decoder fallback and demote the pool 3 → 2, floor 2.** Only a real codec
  error may demote to 1. Never query decoder capability and assume — attempt and degrade.
- **Every card paints the `thumbs/` poster first and keeps it mounted under the texture**, which
  reveals on `onRenderedFirstFrame`. No shimmer, no spinner: an undecoded live card is
  pixel-identical to a static one, so "nothing is moving" is normally cold-cache latency — check the
  pool, not the catalog. Poster, full image and texture must share one `cropAlignment`.
- **Audio is decided at CREATE, not per open.** Everything but the paywall's onboarding clip stays
  `audio: false`; a preview that took focus would pause the user's music.

Read [docs/video-feed.md](../../docs/video-feed.md), and
[docs/media-conventions.md](../../docs/media-conventions.md) before changing an encode.
