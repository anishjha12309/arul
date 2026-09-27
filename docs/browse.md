# Browse — feed order and the New chip

Read before touching `workers/src/cron/build-catalog.ts`, `workers/src/lib/feed-score.ts` or
`lib/features/wallpapers/providers/**`. The category axis itself is CLAUDE.md §1. Ringtone browse:
[ringtones.md](ringtones.md) · card geometry and the live mark: [feed-card.md](feed-card.md).

## Order is ONE SQL clause

```sql
ORDER BY feed_rank ASC NULLS LAST, apply_count DESC, created_at DESC, id ASC          -- wallpapers
ORDER BY feed_rank ASC NULLS LAST, set_count   DESC, created_at DESC NULLS LAST, id ASC  -- ringtones
```

It lives in `build-catalog`'s `buildScope()` and it is the WHOLE of the order: the hand pin, then
lifetime uses, then recency, then `id`. `build-catalog` numbers the result into the catalog JSON's
`feed_rank` field (`rankFor(i) = (i+1)*10`), which the shipped comparator (`feedOrder()` /
`orderedByUse()`, both tabs) already sorts on — so a new order reaches installs that never update. The
unified CMS's feed-order page copies this clause verbatim; keep the two in step.

- **The COLUMN and the JSON FIELD share a name and are different things.** The column is a nullable
  `integer` hand pin the CMS writes, read only by that ORDER BY; the field is a computed POSITION over
  the finished order. That indirection is what let pins ship with no app release.
- **NULL means unpinned** — the state of very nearly every row. Never fold it to 0: 0 is a valid top
  pin. Imports write no rank, so a bulk drop cannot displace the pinned head. Never park curation in
  `sort_order`: every import resets it and the pins die silently.
- **A category IS All restricted to that category** — the same order on All and every chip, so a
  category view never contradicts All. Never add a per-chip rank. New is the one exception (below).
- **The trailing `id` is REQUIRED.** An import is one transaction, so a batch ties on `created_at`, and
  at zero uses everything ties on the counter too. Without a unique final key Postgres may return ties
  differently on any run, re-cutting pages between rebuilds and re-pointing the pager and video pool
  under a scrolling user. The Dart comparator keeps catalog position as its last tier for the same
  reason: `List.sort` is not stable. A tied import is separated by random v4 UUID, which also shuffles
  it across categories — never re-add a round-robin interleave.
- **Counts come from Neon**, incremented in `/media/signed-url` after the entitlement check — never from
  analytics. They reach users only on a rebuild, so the daily cron bumps `content_version` when the
  total moves ([cron.md](cron.md)).
- **No second COMPUTED sort key beside the counter.** A decayed score worked, but the order then depended
  on WHEN it was computed, so worker, CMS and app had to agree on a formula and a clock. A pin is a
  stored integer, so it costs none of that. `apply_score`/`set_score`/`scored_at` hold frozen data —
  never read or sort on them. The accepted cost of the counter is a sticky head (slot 1 earns applies
  partly BECAUSE it is slot 1); tier 1 is the deliberate human lever against it.
- A catalog cached before `feed_rank` existed parses as nothing-ranked and degrades to catalog order.

**The chip ROW's order is a different thing:** the operator's, dragged on the CMS Categories page,
shipped as `app_config.category_order` and applied by `orderedByCms` (`wallpaper.dart`). It reorders
chips and touches nothing inside one. A save bumps `content_version` and rebuilds; without both the
phone keeps its cached `app_config.json`. Installs older than that field keep `compareBrowseCategories`.

## The New chip

**A WINDOW over the feed, not a category any row carries.** Sentinel slug `__new__`, built as chrome
beside All, so it never reaches `categoriesProvider` — which keeps it out of the Upload picker, the CMS
and every import. Never give a row that `category`. **Client-side, and it has to be:** the hourly build
is a no-op while `content_version` holds, so a server-stamped `is_new` would freeze through a quiet
week. `newOrder` (`catalog_providers.dart`) windows at read time.

**New has its OWN order** (owner's call) — three tiers, the first two inside `kNewWindow` (7 days,
inclusive):

1. **Renewed** — `renewed_at` in the window, most recent renew first (the CMS Renew; five renews stack,
   the last on top).
2. **Debuts** — every other row with `published_at` in the window, newest first.
3. **Filler** — only when 1 + 2 hold fewer than `kNewMinItems` (20): the next-newest rows by
   `published_at`, shown most-used first.

- **Pins play NO part in New.** Ties in every tier go by uses DESC, then `id` — never the catalog's
  `feed_rank`, a position with the pins baked in. A bulk publish shares one `published_at`; that is the
  tie the rule is for. `id`, not list index, because the drained ringtone list is re-sorted.
- **A Renew re-stamps `published_at` too**, so older builds — which window New on `published_at` alone —
  still show the row. Undo restores the kept date and clears both renew columns
  ([data-model.md](data-model.md)); the app needs nothing for it. A renew older than the window is just
  a date again.
- **`published_at`, never `created_at`** — `created_at` is import time, so a batch imported long before it
  went live would be born too old to appear.
- **`kNewMinItems` is a FLOOR, not a cap.** Everything inside the window is in — a 40-row drop shows all
  40; a cap would hide half a bulk drop for a week. Filler membership is by RECENCY and only its order is
  by use — sorting the remainder by use would pull in the most-applied rows of all time.
- **Nothing in a scope carrying `published_at` → no chip** (`showNewCategoryProvider` and its ringtone
  twin), or an install on an old page would serve the top of All under the wrong name.

## Where a saved position resolves

Apply-restore resolves its saved page index through `feedOrder()` — the index is a position in the
SERVED list, and raw catalog order restores the wrong wallpaper whenever the saved chip was All. The chip
saved beside it is the one the user was ON (`selectedCategoryProvider`), never the wallpaper's own
`category`, or a restore lands on a category chip at a foreign index. A deep link resolves the same way
(always on All); a ringtone link goes through `ringtoneFeedOrder` and lands the row at the TOP of All.
