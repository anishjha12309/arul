# Browse — feed order and the reel card

Read before touching `workers/src/cron/build-catalog.ts`, `workers/src/lib/feed-score.ts`,
`lib/features/wallpapers/providers/**` or `feed_card_geometry.dart`. The category axis itself is
CLAUDE.md §5b. Ringtone browse: [ringtones.md](ringtones.md).

## Order is ONE SQL clause

```sql
ORDER BY feed_rank ASC NULLS LAST, apply_count DESC, created_at DESC, id ASC          -- wallpapers
ORDER BY feed_rank ASC NULLS LAST, set_count   DESC, created_at DESC NULLS LAST, id ASC  -- ringtones
```

It lives in `build-catalog`'s `buildScope()` and it is the WHOLE of the order. Three tiers: the hand
pin, then lifetime uses, then recency, then `id`. `build-catalog` numbers the result into the catalog
JSON's `feed_rank` field (`rankFor(i) = (i+1)*10`), which the shipped comparator (`feedOrder()` /
`orderedByUse()`, both tabs) already sorts on — so a new order reaches installs that never update.

**The COLUMN and the JSON FIELD share a name and are different things.** The column is a nullable
`integer` the unified CMS writes; it is a sort key, read only by that ORDER BY and never emitted raw.
The JSON field is a computed POSITION over the finished order. That indirection is what let pinning
come back with no app release.

**NULL means unpinned**, and is the state of very nearly every row — so with nothing pinned this
clause is the counter order alone. Never fold NULL to 0: 0 is a valid top pin. Imports write no rank,
which is what stops a bulk drop displacing the pinned head; curation must never be parked in
`sort_order`, because every import resets it and the pins die silently.

The same order applies on every chip, so a filtered view can never contradict All: **a category IS
All restricted to that category.** Never add a per-chip rank.

**The chip ROW's own order is a different thing entirely** and does not live here: it is the
operator's, set by dragging on the unified CMS's Categories page, shipped as
`app_config.category_order` and applied by `orderedByCms` (`wallpaper.dart`). It reorders the chips
and touches nothing about the items inside one. Unlike `feed_rank` it needed an app release, because
no shipped comparator was already reading a catalog field for it — installs older than that release
keep `compareBrowseCategories` and are unharmed. A save in the CMS bumps `content_version` and
rebuilds; without both the phone keeps its cached `app_config.json` and the order never arrives.

- **The trailing `id` is REQUIRED, not cosmetic.** An import is one transaction, so a whole batch
  ties on `created_at`, and at zero uses everything ties on the counter too. Without a unique final
  key Postgres may return tied rows differently on any run — a different plan, a parallel scan, a
  post-VACUUM heap — which re-cuts pages between rebuilds and re-points the pager and the video pool
  under a scrolling user. The Dart comparator keeps catalog position as its last tier for the same
  reason: `List.sort` is not stable, and `_syncFeed` compares served lists by ordered ids.
- **Counts come from Neon** — incremented in `/media/signed-url` after the entitlement check — never
  from analytics. A sampled, client-reported event cannot order a feed. Counts reach users only on a
  rebuild, so the daily cron bumps `content_version` when the total moves.
- **`sort_order` no longer participates in feed order at all.** Imports own it, so leading with it
  meant the feed was really ordered by import sequence with popularity breaking ties. The column is
  still stored and still editable in the CMS; nothing reads it for order.
- The CMS ordering page is READ-ONLY and copies this clause verbatim. Keep the two in step.

## What was removed and may not come back

**No decayed score.** It weighted uses by recency with a stepped newcomer credit, and it worked — but
the order then depended on WHEN it was computed, so three codebases (worker, CMS, app) had to agree
on a formula and a clock rather than on a column. `workers/src/lib/feed-score.ts` is now only the
rank numbering.

**Pins DID come back** (2026-09-02), and they are the exception that proves the rule: a pin is a
stored integer, not a formula, so it costs none of what retiring the score bought. `feed_rank` is a
nullable column again, written by the unified CMS's feed-order page and read by tier 1 of the clause
above. **Do not add a second COMPUTED sort key beside the counter** — that is what may not come back.

The accepted cost of the counter is a sticky head: a lifetime counter only ever rises, and the row at
slot 1 earns applies partly BECAUSE it is at slot 1. Tier 1 is the deliberate lever against that, in
a human's hands rather than a decay's.

`interleaveByCategory` and `composeFeedOrder` are DELETED. The round-robin existed because a
single-transaction import landed as a contiguous single-category block that owned the top of the
feed. The `id ASC` tie-breaker now does that job incidentally and for free: a tied import is
separated by random v4 UUID, which shuffles it across its categories identically on every rebuild.

**The `feed_rank` COLUMN is back on both tables** (dropped 2026-08-25, restored 2026-09-02 by
`db/schema/11_feed_rank.sql`). `apply_score`, `set_score` and `scored_at` still EXIST on both tables
and hold frozen data — unread, and no longer written by `/media/signed-url`, which now increments the
lifetime counter alone. Never read them, never sort on them; no migration drops them. A catalog
cached before `feed_rank` existed parses as nothing-ranked and degrades to catalog order rather than
failing to parse.

## Where a saved position resolves

Apply-restore resolves its saved page index through `feedOrder()` — the index is a position in the
SERVED list, and raw catalog order restores the wrong wallpaper whenever the saved chip was All. A
deep link resolves the same way (always on All); a ringtone link goes through `ringtoneFeedOrder` and
lands the row at the TOP of All. The link's `lang` always wins over the user's Settings pick
([deep-links.md](deep-links.md)).

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
