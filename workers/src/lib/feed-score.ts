
/** Gap between consecutive ranks — sparse, so a later reorder renumbers without cascading. */
export const RANK_STEP = 10;

/**
 * The rank emitted for the row at position `index` of the feed order.
 */
export function rankFor(index: number): number {
  return (index + 1) * RANK_STEP;
}
