
/** Gap between consecutive ranks — sparse, so a later reorder renumbers without cascading. */
export const RANK_STEP = 10;

/**
 * The rank emitted for the row at position `index` of the feed order.
 */
export function rankFor(index: number): number {
  return (index + 1) * RANK_STEP;
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** A clip's newness boost fades from full to nothing over this window after its publish or CMS Renew (owner). */
export const STATUS_FRESH_MS = 7 * DAY_MS;

/** How much the most-used clip and a clip published right now each out-draw an old, unused one (1 + 3 = 4×). */
export const STATUS_USE_BOOST = 3;
export const STATUS_FRESH_BOOST = 3;

export interface StatusWeightInput {
  uses: number;
  /** The later of published_at and renewed_at -> a Renew restarts the boost; null = no boost. */
  freshAt: Date | null;
}

/**
 * The draw weight of one status: 1 + use boost + fresh boost, so every clip keeps a real chance at the top.
 *
 * Uses are LOG-scaled against the busiest clip -> one viral clip cannot pin itself to slot 1 every hour,
 * and the scale needs no retuning as the counters grow. A future timestamp counts as fresh, never above it.
 */
export function statusWeight(row: StatusWeightInput, maxUses: number, now: Date): number {
  const use = maxUses > 0 ? Math.log1p(Math.max(0, row.uses)) / Math.log1p(maxUses) : 0;
  const age = row.freshAt ? now.getTime() - row.freshAt.getTime() : Number.POSITIVE_INFINITY;
  const fresh = Math.max(0, 1 - Math.max(0, age) / STATUS_FRESH_MS);
  return 1 + STATUS_USE_BOOST * use + STATUS_FRESH_BOOST * fresh;
}

/**
 * Weighted random order without replacement (Efraimidis–Spirakis): each row draws log(u)/w, highest first.
 * P(row lands first) is its weight over the total, and every later slot follows the same rule on the rest.
 * `random` must return [0, 1) like Math.random -> 1 - r keeps log() finite.
 */
export function weightedShuffle<T>(rows: readonly T[], weight: (row: T) => number, random = Math.random): T[] {
  return rows
    .map((row) => ({ row, key: Math.log(1 - random()) / Math.max(weight(row), Number.MIN_VALUE) }))
    .sort((a, b) => b.key - a.key)
    .map((e) => e.row);
}
