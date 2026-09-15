# Browse — feed order and the reel card

Read before touching `workers/src/cron/build-catalog.ts`, `workers/src/lib/feed-score.ts` or
`lib/features/wallpapers/providers/**`. The category axis itself is CLAUDE.md §5b.
Ringtone browse: [ringtones.md](ringtones.md). Card geometry: [feed-card.md](feed-card.md).

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

The same order applies on All and every category chip, so a category view can never contradict All:
**a category IS All restricted to that category.** Never add a per-chip rank. The New chip is the
one exception and has its own order — see below.

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
- The CMS feed-order page copies this clause verbatim. Keep the two in step.

## The New chip

**A WINDOW over the feed, not a category any row carries.** Sentinel slug (`__new__`), built as
chrome beside All in both chip rows, so it never reaches `categoriesProvider` — which is what keeps
it out of the Upload picker, the CMS and every import. Never give a row this `category` value.

**Client-side, and it has to be:** the hourly build is a no-op while `content_version` holds, so a
server-stamped `is_new` would freeze a row as new through a quiet week. `newOrder`
(catalog_providers.dart) windows at read time; the catalog only carries the columns.

**New has its OWN order — the one chip that is not All restricted** (owner's call, 2026-09-15, build
1.0.0+78). Three tiers, the first two inside `kNewWindow` (7 days, inclusive):

1. **Renewed** — `renewed_at` in the window, most recent renew first. The operator taps **Renew** on a
   row of the unified CMS's Feed order page; renew five and they stack, the last one on top.
2. **Debuts** — every other row with `published_at` in the window, newest publish first.
3. **Filler** — only when 1 + 2 hold fewer than `kNewMinItems` (20): the next-newest rows by
   `published_at` make up the floor, shown most-used first.

- **Pins play NO part in New.** Ties in every tier go by uses DESC, then `id` — never by the catalog's
  `feed_rank`, which is a position with the pins baked in. A bulk publish is one transaction, so a
  whole batch shares one `published_at`; that is the tie the rule is for. `id` rather than list index
  because the drained ringtone list is re-sorted by `sort_order`/title.
- **A CMS Renew writes `renewed_at = now()` AND `published_at = now()`** in one UPDATE, with the
  `content_version` bump (db/schema/19_renewed_at.sql). Re-stamping `published_at` is what lets builds
  before 1.0.0+78 — which window on `published_at` alone, in their old pins-then-applies order — still
  show a renewed row in New. The date it overwrites is kept in `pre_renew_published_at` (first renew
  of a chain only), and the CMS's **Undo** writes it back and clears both renew columns, so the row
  returns exactly where it was (db/schema/20_renew_undo.sql). The app needs nothing for Undo: a null
  `renewed_at` is simply not tier 1. A renew older than the window is just a date again.
- **`published_at`, never `created_at`** — created_at is import time, so a batch imported long before
  it went live would be born too old to appear. Debut date, DB-trigger stamped
  ([data-model.md](data-model.md)).
- **`kNewMinItems` is a FLOOR, not a cap.** Everything inside `kNewWindow` is in — a 40-row drop
  shows all 40; a thin week tops up by recency to 20, an empty one serves the newest 20. A cap would
  hide half a bulk drop behind All for a week. Membership of the filler is by RECENCY and only its
  order is by use — sorting the whole remainder by use would pull in the most-applied rows of all time.
- **Nothing in the scope carrying `published_at` → no chip** (`showNewCategoryProvider` and its
  ringtone twin, each on its own scope). An install on a page built before the column would serve the
  top of All under the wrong name.

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
SERVED list, and raw catalog order restores the wrong wallpaper whenever the saved chip was All. The
chip saved beside it is the one the user was ON (`selectedCategoryProvider`), never the wallpaper's
own `category`: before 1.0.0+78 an apply from All or New saved the latter and restored onto a
category chip at a foreign index. A
deep link resolves the same way (always on All); a ringtone link goes through `ringtoneFeedOrder` and
lands the row at the TOP of All. The link's `lang` always wins over the user's Settings pick
([deep-links.md](deep-links.md)).

Reel card geometry and the live mark: [feed-card.md](feed-card.md).
