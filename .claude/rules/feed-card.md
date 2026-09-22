---
description: Reel card geometry lives in one file, and the live mark is static.
paths:
  - "lib/features/wallpapers/presentation/feed_card_geometry.dart"
  - "lib/features/wallpapers/presentation/feed_screen.dart"
---

- **All reel geometry lives ONLY in `feed_card_geometry.dart`**, pinned by its test. `cardAspect` is
  a REQUEST — the card is height-clamped on a real phone, so read the solved size, never the
  constant. `gutter` buys width, `minPeek` buys height.
- **The floor is split either side of the reel** — screen-anchored things offset by
  `underhang + peek + gap`, never by the whole floor. It is frequently zero.
- **1.78 is a BOUNDARY, not a dial**: below it the crop flips to top/bottom and costs crowns and feet
  on devotional art. `ViewerMedia.cropAlignment` is LIVE — do not delete it as unused.
- **Skeleton and reel must read the SAME geometry**, or the card resizes when the first page lands.
- **`LiveMark` is STATIC and never text** — it shares a card with a live `Texture`, and the `LIVE`
  pill it replaced shipped untranslated English in six locales. No shadow: contrast comes from a dark
  fill INSIDE the disc, because a shadow bleeds onto the artwork.

Read [docs/feed-card.md](../../docs/feed-card.md) before moving a knob; feed ORDER is
[docs/browse.md](../../docs/browse.md).
