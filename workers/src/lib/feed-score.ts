/**
 * Merit ranking — THE feed order, for wallpapers and ringtones alike.
 *
 * Replaces hand-written pins (`feed_rank`, retired 2026-08-25). The order is now
 * computed from one signal the app already collects — applies/sets — with two
 * terms:
 *
 *   total = decayed uses + newcomer credit
 *
 * WHY DECAY, NOT THE RAW COUNT. `apply_count` only ever rises, and the row at
 * slot 1 earns applies partly BECAUSE it is at slot 1. Ordering on it freezes
 * the head forever: nothing below can arithmetically catch a number that never
 * falls. `apply_score` is the same event stream weighted so an apply from
 * HALF_LIFE_DAYS ago counts half as much as one today, so a row that stops
 * earning applies falls on its own, with nobody touching it. That is the whole
 * point of the feature.
 *
 * WHY A NEWCOMER CREDIT. A brand-new row has zero uses, and zero is exactly why
 * it would sit at the bottom forever — never seen, so never applied, so never
 * seen. That is the same lock-in as the frozen head, mirrored. Every row instead
 * enters as if it had NEWCOMER_CREDIT applies today, and that credit halves every
 * NEWCOMER_HALF_LIFE_DAYS: a real spell of exposure to earn real applies, then it
 * falls back to what it earned.
 *
 * THE CREDIT IS QUANTIZED TO WHOLE HALF-LIVES, AND THAT IS LOAD-BEARING. A credit
 * that varied continuously with age would make age a strict total order over
 * every unused row — and since a bulk import shares one `created_at`, the newest
 * import would own the opening screens as a single-category block. That is the
 * exact defect `interleaveByCategory` exists to prevent (2026-08-14: 20 Perumal
 * in slots 1-20, four categories missing from the first screens). Stepping the
 * credit makes every row in the same cohort tie EXACTLY, so the tie-break —
 * interleaved catalog position — governs them and the cohort stays category-mixed.
 * Ties are the mechanism, not an accident: never smooth this into a continuous
 * curve.
 *
 * CREDIT_FLOOR does the same job at the other end: past it the credit is zeroed
 * rather than left as a vanishing fraction, so the long tail of never-applied
 * rows ties at exactly 0 and stays interleaved instead of being ordered by age.
 *
 * STABILITY BETWEEN REBUILDS. Two decayed scores keep their ratio as time passes
 * (both are multiplied by 0.5^(Δt/H) around their own `scored_at`), so the merit
 * half of the order does not churn on a clock — it moves only when a real apply
 * lands. The credit half moves in discrete steps, at most once per
 * NEWCOMER_HALF_LIFE_DAYS per row. The feed therefore holds still under a
 * scrolling user between rebuilds, which matters because the app diffs served
 * lists by ordered ids and a reshuffle re-points the pager and the video pool.
 *
 * KNOBS ARE CODE CONSTANTS, NOT CONFIG. The write path in /media/signed-url
 * decays with HALF_LIFE_SECONDS inline in its UPDATE; if a stored knob ever
 * disagreed with the one used at read time, every score would be silently wrong.
 * Reading config there would also add a DB round trip to the app's most
 * latency-sensitive route. Tuning is a deploy, deliberately.
 *
 * The honest limit: with no view counting, an apply is still partly a function of
 * where the row was shown. Decay and the credit are the mitigation, not a cure —
 * an apply-RATE would need an impressions denominator we deliberately do not
 * collect (it would mean a per-session write; this feature adds none).
 */

/** Half-life of an apply/set, in days. An apply this old counts half. */
export const HALF_LIFE_DAYS = 30;

/** Same value in seconds — the write path decays in SQL and needs it there. */
export const HALF_LIFE_SECONDS = HALF_LIFE_DAYS * 24 * 60 * 60;

/** Virtual uses a row enters the feed with, so it gets seen at all. */
export const NEWCOMER_CREDIT = 2;

/** The credit halves every this many days — stepped, never continuous. */
export const NEWCOMER_HALF_LIFE_DAYS = 7;

/** Below this the credit is zeroed, so the old tail ties at exactly 0. */
export const CREDIT_FLOOR = 0.01;

/** Gap between consecutive computed ranks, sparse like the pins it replaced. */
export const RANK_STEP = 10;

const DAY_MS = 24 * 60 * 60 * 1000;

/** The rank emitted for the row at position `index` of the computed order. */
export function rankFor(index: number): number {
  return (index + 1) * RANK_STEP;
}

/**
 * Coerce a Postgres `double precision` to a JS number.
 *
 * postgres.js runs with fetch_types:false (required for Hyperdrive), which hands
 * several numeric types back as STRINGS — the same trap `apply_count` documents
 * in build-catalog. Anything unparseable normalizes to 0: a row loses its merit
 * and falls to the tail, which is always the safe direction.
 */
export function toScore(v: unknown): number {
  if (typeof v === "number") return Number.isFinite(v) && v > 0 ? v : 0;
  if (typeof v === "string") {
    const n = Number(v.trim());
    return Number.isFinite(n) && n > 0 ? n : 0;
  }
  if (typeof v === "bigint") return Number(v);
  return 0;
}

/**
 * Coerce a Postgres `timestamptz` to a Date, or null.
 *
 * Also fetch_types:false: timestamps arrive as ISO-8601 "…Z" strings, not Dates.
 * An unreadable value is null, which costs the row its decay reference and
 * scores it 0 rather than throwing mid-build.
 */
export function toDate(v: unknown): Date | null {
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v;
  if (typeof v === "string") {
    const d = new Date(v);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  return null;
}

/** What a row contributes to the order, and why — the CMS renders this verbatim. */
export interface ScoreBreakdown {
  /** Decayed uses: real applies/sets, weighted by how recent they are. */
  recent: number;
  /** Newcomer credit: the fading head start every row enters with. */
  credit: number;
  /** recent + credit — the only number the sort reads. */
  total: number;
}

/**
 * Decay a stored score forward to `now`.
 *
 * The stored number is meaningless on its own: `apply_score` was last decayed at
 * `scored_at`, so two rows both reading 5.0 are NOT equal if one was applied
 * yesterday and the other in March. NOTHING may compare the raw column — always
 * decay to a common instant first.
 */
export function decayedUses(
  score: unknown,
  scoredAt: unknown,
  now: Date,
): number {
  const s = toScore(score);
  if (s <= 0) return 0;
  const at = toDate(scoredAt);
  // No reference instant means the score was never written by the apply path;
  // treat it as unearned rather than as "applied right now".
  if (!at) return 0;
  const elapsed = now.getTime() - at.getTime();
  // Clock skew between the DB and the build: never inflate a score.
  if (elapsed <= 0) return s;
  return s * Math.pow(0.5, elapsed / (HALF_LIFE_DAYS * DAY_MS));
}

/**
 * The fading head start, stepped to whole half-lives (see the header — the ties
 * this produces are what keeps a cohort category-interleaved).
 */
export function newcomerCredit(createdAt: unknown, now: Date): number {
  const at = toDate(createdAt);
  // A row with no creation date cannot be shown to be new, so it gets nothing.
  if (!at) return 0;
  const ageDays = (now.getTime() - at.getTime()) / DAY_MS;
  const steps = ageDays <= 0 ? 0 : Math.floor(ageDays / NEWCOMER_HALF_LIFE_DAYS);
  const credit = NEWCOMER_CREDIT * Math.pow(0.5, steps);
  return credit < CREDIT_FLOOR ? 0 : credit;
}

/** The full score for one row, with its terms kept separate for the CMS. */
export function feedScore(
  row: { score: unknown; scoredAt: unknown; createdAt: unknown },
  now: Date,
): ScoreBreakdown {
  const recent = decayedUses(row.score, row.scoredAt, now);
  const credit = newcomerCredit(row.createdAt, now);
  return { recent, credit, total: recent + credit };
}

// ── Feed order ────────────────────────────────────────────────────────────────

// ── Feed composition ──────────────────────────────────────────────────────────

/**
 * Deal rows out ONE PER CATEGORY, preserving each category's own order.
 *
 * WHY THIS IS HERE AND NOT IN THE DATABASE. An import is one transaction, so its
 * rows share `created_at` and default to `sort_order = 0` — they arrive as a
 * solid block at the head of the feed. On 2026-08-14 that put 20 Perumal
 * wallpapers in slots 1-20 and 10 Sivan in 21-30, with four categories missing
 * from the opening screens entirely. Sorting cannot fix it (those rows genuinely
 * ARE the newest); only interleaving can.
 *
 * The first fix wrote the interleaved order into `sort_order` from a script. It
 * worked, but every future import re-created the defect until someone remembered
 * to re-run it — a manual step is a step that eventually doesn't happen, usually
 * right after an import when everyone is looking. Computing it HERE makes it
 * unforgettable: publish is the only trigger, there is no stored state to go
 * stale, and a hand-inserted row or a brand-new category is handled for free.
 *
 * The division of labour this creates:
 *   `sort_order` / `created_at` → order WITHIN a category (the SQL ORDER BY)
 *   this function               → order ACROSS categories
 *
 * Category chips are unaffected. The app filters this one page set by category,
 * and interleaving never reorders two rows of the SAME category relative to each
 * other — so a chip still reads newest-first (CLAUDE.md §5b).
 *
 * The All chip is unaffected too, for rows anyone has actually used: the app
 * serves `apply_count DESC, ties in catalog order`, so this only ever decides
 * the order of the rows that TIE — which at zero data is all of them.
 *
 * Biggest category leads each round. With unequal counts the largest category
 * inevitably tails the feed alone; leading with it keeps that tail shortest.
 * Idempotent and a pure function of the row list: re-running it on its own
 * output returns that output unchanged, so a rebuild never churns the feed.
 */
export function interleaveByCategory<T extends Record<string, unknown>>(
  rows: T[],
): T[] {
  const queues = new Map<string, T[]>();
  for (const r of rows) {
    const key = String(r["category"] ?? "");
    const q = queues.get(key);
    if (q) q.push(r);
    else queues.set(key, [r]);
  }
  // One category (or none) — interleaving is a no-op. Returning early also keeps
  // a single-category catalog byte-identical to plain catalog order.
  if (queues.size < 2) return rows;

  const cycle = [...queues.keys()].sort((a, b) => {
    const bySize = queues.get(b)!.length - queues.get(a)!.length;
    // Tie on size → name, so the cycle never depends on Map iteration luck.
    return bySize !== 0 ? bySize : a.localeCompare(b);
  });

  const cursor = new Map<string, number>(cycle.map((c) => [c, 0]));
  const out: T[] = [];
  // Every full pass emits at least one row while any queue has rows left.
  while (out.length < rows.length) {
    for (const c of cycle) {
      const q = queues.get(c)!;
      const i = cursor.get(c)!;
      if (i >= q.length) continue;
      out.push(q[i]);
      cursor.set(c, i + 1);
    }
  }
  return out;
}

/**
 * Page order: highest merit score first, ties interleaved by category.
 *
 * THE feed order, for every install. Until 2026-08-25 this hoisted the admin's
 * `feed_rank` pins and left the rest of the ordering to the app; pinning is gone
 * (workers/src/lib/feed-score.ts has the why) and the score computed here IS the
 * order. It is emitted back out as `feed_rank`, so the comparator already
 * shipped in every install sorts on it — merit ordering reaches phones that
 * never update, in their category chips as well as All.
 *
 * THE INTERLEAVE RUNS INSIDE EACH TIED GROUP, NOT OVER THE WHOLE LIST. Ties are
 * the common case, not the exception: every never-applied row of the same
 * newcomer cohort scores EXACTLY the same, which is most of the catalog most of
 * the time. Round-robinning each group is what stops a bulk import — one
 * transaction, one `created_at`, therefore one cohort — from owning the opening
 * screens as a single-category block (the 2026-08-14 defect interleaveByCategory
 * was written for). Merit is never overridden: a row only ever meets the
 * round-robin against rows it is genuinely level with.
 *
 * Interleaving the WHOLE list first and sorting after also works on a fresh
 * build but is NOT idempotent — re-interleaving an already-merit-ordered list
 * re-shuffles the tie positions. Grouping is, because interleaveByCategory maps
 * an interleaved run to itself.
 *
 * Ties inside a group break on incoming catalog position, decorated explicitly
 * rather than leaning on Array.sort stability — the same total-order discipline
 * the SQL ORDER BY keeps. Without it a rebuild could re-cut pages under a user
 * mid-pagination.
 */
export function composeFeedOrder<T extends Record<string, unknown>>(
  rows: T[],
  now: Date,
  scoreCol: string,
): T[] {
  const decorated = rows.map((row, i) => ({
    row,
    i,
    total: feedScore(
      {
        score: row[scoreCol],
        scoredAt: row["scored_at"],
        createdAt: row["created_at"],
      },
      now,
    ).total,
  }));
  decorated.sort((a, b) => (b.total !== a.total ? b.total - a.total : a.i - b.i));

  const out: T[] = [];
  for (let i = 0; i < decorated.length; ) {
    let j = i;
    while (j < decorated.length && decorated[j]!.total === decorated[i]!.total) j++;
    // A group of one is the overwhelming case once real applies exist; skip the
    // Map churn for it.
    out.push(
      ...(j - i === 1
        ? [decorated[i]!.row]
        : interleaveByCategory(decorated.slice(i, j).map((d) => d.row))),
    );
    i = j;
  }
  return out;
}
