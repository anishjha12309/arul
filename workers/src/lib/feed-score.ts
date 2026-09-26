
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
