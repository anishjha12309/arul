/**
 * Feed order — for wallpapers and ringtones alike.
 *
 *   ORDER BY feed_rank ASC NULLS LAST, <use count> DESC, created_at DESC, id ASC
 *
 * THREE TIERS, STILL ONE SQL CLAUSE. `feed_rank` is a nullable integer column on
 * both content tables that the CMS writes by hand (retired 2026-08-25, restored
 * 2026-09-02). NULL means unpinned and is the state of very nearly every row, so
 * tier 1 is empty until someone pins something and the feed is the use counter
 * alone — which is what it was for the week in between. NULL is never folded to
 * 0, because 0 is a valid top pin. Imports never write the column, so a bulk
 * drop cannot displace the hand-written head; that is the safety property the
 * first attempt at this feature lacked, when curated order lived in `sort_order`
 * and every import silently reset it.
 *
 * THE COLUMN AND THE CATALOG FIELD SHARE A NAME AND ARE NOT THE SAME THING. The
 * column is a sort key: read by that ORDER BY, never emitted raw. The catalog's
 * `feed_rank` field is a computed POSITION (10, 20, 30 …) stamped over whatever
 * order the clause returned. That indirection is what carries a new order to
 * installs that never update — the app's comparator sorts on the field it has
 * always sorted on, and never learns that pinning came back.
 *
 * THE ORDER IS SQL, NOT MATHS, AND THAT IS THE WHOLE POINT. Ranking used to be
 * computed in JS from a decaying copy of the use counter plus a fading
 * newcomer credit (`apply_score`/`set_score`/`scored_at`, retired 2026-08-27).
 * Every reader had to decay both halves to a common instant before it could
 * compare two rows, which meant the CMS, build-catalog and the app each had to
 * agree on a clock as well as on a formula — three places to drift, and the
 * order of the feed depended on WHEN it was computed. The lifetime counter the
 * app already collects orders the feed directly now: one column, one ORDER BY,
 * the same answer at any hour. A pin is a stored integer, not a formula, so it
 * costs that property nothing.
 *
 * WHAT THIS FILE STILL OWNS. Only the rank NUMBERING. The sort itself lives in
 * each build-catalog's SQL, because that is the one place all the tiers can
 * read the same statement.
 *
 * THE TIE-BREAKERS ARE LOAD-BEARING, NOT DECORATION. Content arrives via bulk
 * imports (one transaction per batch), so a whole batch shares an identical
 * `created_at`, and at zero data every row shares a use count of 0. Without a
 * unique final key the sort is not total, and Postgres may return tied rows in
 * a different order on any run — a different plan, a parallel scan, or simply a
 * different heap layout after a VACUUM. Pages are cut every PAGE_SIZE rows in
 * returned order, so that silently reshuffles which items land on which page
 * between rebuilds: the feed reorders under users for no reason, and anyone
 * mid-pagination during a rebuild can see an item twice or miss it entirely.
 * `id` is unique, so appending it makes the order reproducible forever.
 *
 * A BULK IMPORT DOES NOT CLUMP BY CATEGORY, which is what the retired
 * `interleaveByCategory` round-robin existed to prevent (2026-08-14: 20 Perumal
 * wallpapers in slots 1-20, four categories missing from the opening screens).
 * That defect came from ordering an import in INSERTION order. These rows tie
 * on both the counter and `created_at`, so `id ASC` decides them — and ids are
 * random v4 UUIDs, which shuffles a batch across its categories for free and
 * identically on every rebuild.
 *
 * The honest limit, unchanged from the decayed version: with no view counting,
 * a use is still partly a function of where the row was shown. A lifetime
 * counter also only ever rises, so the head of the feed is sticky. Tier 1 is
 * the deliberate answer to that — a hand that can put a row in front of users
 * the counter would take months to notice — rather than a decay that made the
 * order depend on the clock.
 */

/** Gap between consecutive ranks — sparse, so a later reorder renumbers without cascading. */
export const RANK_STEP = 10;

/**
 * The rank emitted for the row at position `index` of the feed order.
 *
 * build-catalog writes this into the catalog JSON under the `feed_rank` name
 * the app has always sorted on, so the order reaches installs that never
 * update. It is a position over the finished order, never the column read back
 * off a row.
 */
export function rankFor(index: number): number {
  return (index + 1) * RANK_STEP;
}
