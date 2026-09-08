---
description: Feed order is one SQL clause; category is the axis.
paths:
  - "workers/src/cron/build-catalog.ts"
  - "workers/src/lib/feed-score.ts"
  - "lib/features/wallpapers/providers/**"
---

- **`category` is THE browse axis**; `type` (static/live) is a rendering hint, never a filter or tab.
  Chips derive from each tab's own catalog; the two lists differing is correct.
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
- **The New chip is a WINDOW, not a category.** Sentinel `__new__`, chrome beside All, never in
  `categoriesProvider` — so never in the Upload picker or CMS, and never on a row. Client-side
  `published_at` window (created_at would bury a late-published batch); `kNewMinItems` is a FLOOR,
  not a cap; `newSelection` hands back CATALOG order, keeping New All restricted.

Read [docs/browse.md](../../docs/browse.md) first; geometry is [feed-card.md](feed-card.md).
