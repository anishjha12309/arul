---
description: Feed order is one SQL clause; category is the axis.
paths:
  - "workers/src/cron/build-catalog.ts"
  - "workers/src/lib/feed-score.ts"
  - "lib/features/wallpapers/providers/**"
  - "lib/features/wallpapers/presentation/feed_card_geometry.dart"
  - "lib/features/wallpapers/presentation/feed_screen.dart"
---

- **`category` is THE browse axis**; `type` (static/live) is a rendering hint, never a filter or tab.
  Chips derive from each tab's own catalog, so the two lists differing is correct.
- **Chip ROW order is the operator's** when set: CMS `categories.picker_order` → `app_config
  .category_order` keyed by SCOPE → `orderedByCms`. It SORTS only (never adds or hides a chip); absent
  or empty falls back to `compareBrowseCategories` / `compareRingtoneCategories`; a partial list puts
  the named slugs first. An explicit order beats `others`-last.
- **Order is ONE SQL clause in `build-catalog`**: `feed_rank ASC NULLS LAST, apply_count DESC,
  created_at DESC, id ASC` (`set_count` + a second `NULLS LAST` for ringtones), numbered into the
  catalog's `feed_rank`, which the shipped comparator sorts on. Same order on every chip — a category
  IS All restricted. Never add a per-chip rank.
- **The trailing `id` is REQUIRED**: an import batch ties on `created_at`, and without a unique key
  Postgres re-cuts pages under a scrolling user. The Dart comparator keeps catalog position last.
- **Pins are the ONLY hand tier.** `feed_rank` is nullable, NULL = unpinned (~every row); never fold
  NULL to 0 — 0 is a valid top pin. `apply_score`/`set_score`/`scored_at` are unread; `sort_order`
  reaches no user and every import resets it — never park curation there.
- **Reel card geometry lives ONLY in `feed_card_geometry.dart`**, pinned by its test; `cardAspect` is
  a request — read the solved size. `gutter` buys width, `minPeek` buys height; screen-anchored
  things offset by `underhang + peek + gap`.

Read [docs/browse.md](../../docs/browse.md) before changing order or geometry.
