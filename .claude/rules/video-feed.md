---
description: Decoder budget, player reuse, reel visibility and the poster-first reveal.
paths:
  - "android/**/feedvideo/**"
  - "lib/features/wallpapers/data/**"
  - "lib/app/widgets/reel/**"
  - "lib/app/shell/**"
  - "lib/features/wallpapers/presentation/viewer_media.dart"
---

Budget SoCs fit about two concurrent 1080p hardware decoder sessions, and exceeding that fails
SILENTLY — a software fallback, a green edge strip, or a black card.

- **Live MP4s are exactly 1024×1824** — `width % 128 == 0`, `height % 32 == 0`, inside the 1088×1920
  hardware cap. Anything else hits the green-edge / software-decode bug class.
- **Players are REUSED**: `setMediaItem` swap, never dispose+recreate per swipe.
- **Open a local FILE, never a CDN stream** — `ensureCached` first, poster until it lands, the url
  only when the transfer failed. A looping stream re-downloads the clip every lap (back buffer 0)
  and under-runs on any pipe below its 1.3–9.8 Mbit/s. The current card holds the neighbours' bytes.
- **Only a re-`open()` hides a painted texture** — a rebuffer does not. A non-decoder error after
  first paint must leave the card alone; the decoder-error retry/demote path is untouched.
- **ONE process-global EventChannel hub** — a second listener silently steals the single native sink.
- **Software-decoder fallback demotes the pool 3 → 2, floor 2**; only a real codec error goes to 1.
  Never query decoder capability and assume — attempt and degrade. The budget is shared by both reels.
- **Two reel pools never decode at once**: Wallpapers↔Status awaits the leaving pool's full release
  before the entering one claims; every other leave keeps the 3 s grace.
- **Poster first, mounted under the texture, revealed on `onRenderedFirstFrame`.** No shimmer or
  spinner: an undecoded live card looks static, so "nothing is moving" is cold-cache latency — check
  the pool, not the catalog. Poster, full image and texture share one `cropAlignment`.
- **Audio is decided at CREATE, not per open.** Only the paywall's shared player and the status pool
  are audible. **Nothing plays unless `visible`**: another tab, a pushed page route or the background
  pauses it (a dialog does not), and a focus loss or headphones-out holds it until a tap.

Read [docs/video-feed.md](../../docs/video-feed.md), and
[docs/media-conventions.md](../../docs/media-conventions.md) before changing an encode.
