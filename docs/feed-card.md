# Feed card — reel geometry and the live mark

Read before touching `feed_card_geometry.dart` or anything that measures, offsets or overlays the
reel card. Feed ORDER and the chips are a different area: [browse.md](browse.md).

## Reel card geometry

**All of it lives in `feed_card_geometry.dart`, pinned by its test.** The numbers are Shubh's tile
(owner's instruction, measured from Shubh's own accessibility tree on a Nothing A001): 16 dp gutters,
16 dp gap, 24 radius, peek pinned at `minPeek` (25), **1:1.86 asked** and no floor. `card + gap +
peek + floor` fills the reel exactly. Re-measure Shubh (`uiautomator dump` — its screenshots are
FLAG_SECURE-blank) before moving a knob.

- **The card is HEIGHT-CLAMPED on a real phone, so `cardAspect` is a request and the reel decides
  what ships.** Read the solved size, never the constant. `gutter` buys WIDTH only; `minPeek` is the
  only knob that buys height.
- **The floor is split either side of the reel** — `headroom` above, `underhang` below, with
  `underhang` carrying the odd pixel so the two sum exactly. It is frequently ZERO, because at 1.86
  the card consumes the whole reel on an ordinary phone; it earns its keep on tall screens. Anything
  screen-anchored offsets by `underhang + peek + gap`, **not** the whole floor.
- Short-screen degradation, in order: floor, then peek down to `minPeek`, only then the card. A card
  taller than its viewport cannot snap.
- **1.78 (9:16) is a BOUNDARY, not a dial.** Above it the crop is horizontal and cheap; below it it
  flips to top/bottom, costing crowns and feet on devotional art. `ViewerMedia.cropAlignment` biases
  the window UP for that case and is LIVE on the phones this ships to — do not delete it as unused.
- Skeleton and reel must read the SAME geometry, or the card resizes when the first page lands.
- Rejected shapes, do not revisit: device-aspect 1:2.22 · Pakiza's 1:1.63 verbatim · short-and-wide
  1:1.40.

## The live mark

A live card is marked by `LiveMark` ONLY — a 24 dp glass disc with a play glyph, top-right, and
**STATIC**: it shares a card with a live `Texture`, so the cheapest mark is one that never asks for a
frame. **Never text** — the `LIVE` pill it replaced shipped untranslated English in six locales.

Its inset is **22, not the action row's 14**: at 14 it rides the corner arc and reads as stuck to the
rim. **No shadow** (owner's call): it shipped with the rail glyphs' dark halo as insurance against
washing out on a white temple, and on the real catalog that halo read as a black smudge on every
wallpaper — a louder failure than the one it insured against. Contrast comes from a dark fill INSIDE
the disc; a shadow bleeds outside the object onto the artwork, which is the whole difference.

**The two over-media glass objects share a RIM (`overMediaGlassBorder`) but NOT a fill**, and that
split is deliberate: the Share circle sits inside the bottom scrim so it can be the bright half
(`overMediaGlassFill`, ivory); `LiveMark` sits on raw artwork where the ground is unknown, so it must
be the dark half (`overMediaInkFill`). Ivory chrome on a white marble temple is invisible at ANY
alpha — raising it makes it whiter, not clearer. Never unify the two fills.
