---
description: Feed order is one SQL clause; category is the axis.
paths:
  - "workers/src/cron/build-catalog.ts"
  - "workers/src/lib/feed-score.ts"
  - "lib/features/wallpapers/providers/**"
  - "lib/features/wallpapers/presentation/feed_card_geometry.dart"
  - "lib/features/wallpapers/presentation/feed_screen.dart"
---

**`category` is THE browse axis** for wallpapers and ringtones; `type` (static/live) is a rendering
hint and must never become a filter or a tab. Chips derive from each tab's own catalog, so the two
lists differing is correct.

- **Order is ONE SQL clause in `build-catalog`** — `feed_rank ASC NULLS LAST, apply_count DESC,
  created_at DESC, id ASC` (`set_count`, plus a second `NULLS LAST` on `created_at`, for ringtones) —
  numbered into the catalog JSON's `feed_rank`, which the shipped comparator sorts on, so a new order
  reaches installs that never update. The same order applies on every chip: a category IS All
  restricted to that category. Never add a per-chip rank.
- **The trailing `id` is REQUIRED.** An import is one transaction, so a whole batch ties on
  `created_at`; without a unique final key Postgres may return tied rows differently on any run,
  which re-cuts pages and re-points the pager and the video pool under a scrolling user. The Dart comparator keeps catalog
  position as its last tier for the same reason.
- **Pins lead, and are the ONLY hand tier.** `feed_rank` is a nullable column the unified CMS writes
  (restored 2026-09-02); NULL means unpinned and is ~every row, so with nothing pinned the clause is
  the counter order alone. Never fold NULL to 0 — 0 is a valid top pin. No decayed score and no
  second sort key beside the counter: `apply_score`/`set_score`/`scored_at` still exist but are
  unread, and `sort_order` participates in no ordering decision that reaches a user — curation must
  never be parked there, because every import resets it.
- **Reel card geometry lives ONLY in `feed_card_geometry.dart`**, pinned by its test. The card is
  height-clamped, so `cardAspect` is a request — read the solved size. `gutter` buys width; `minPeek`
  is the only knob that buys height. The floor splits `headroom`/`underhang` around the reel, so
  anything screen-anchored offsets by `underhang + peek + gap`.

Read [docs/browse.md](../../docs/browse.md) before changing order or geometry.
