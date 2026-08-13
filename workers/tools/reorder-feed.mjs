/**
 * Rewrite `sort_order` so the feed deals ONE PER CATEGORY instead of letting a
 * bulk import own the opening screens.
 *
 * WHY THIS EXISTS. An import is one transaction, so its rows share `created_at`
 * and arrive as a solid consecutive block. build-catalog emits
 * `sort_order ASC, created_at DESC, id ASC`, and the app's All chip serves
 * `apply_count DESC, ties in catalog order` — so before any applies accrue, All
 * IS catalog order. On 2026-08-14 that meant slots 1-20 were all Perumal and
 * 21-30 all Sivan, with four categories absent from the opening screens.
 * Sorting cannot fix that (those rows genuinely ARE the newest); only
 * interleaving can, and `sort_order` is the one lever that does it WITHOUT an
 * app release — it reaches every installed build on the next catalog rebuild.
 *
 * WHAT IT DOES. Categories are dealt round-robin, biggest first, and each
 * category is drained newest-first. So the top of All becomes one wallpaper from
 * every deity before the second of any, while a CATEGORY chip still reads
 * newest-first (CLAUDE.md §5b) — this reorders ACROSS categories, never within
 * one.
 *
 * RE-RUN IT AFTER EVERY BULK IMPORT. New rows default to `sort_order = 0`, which
 * sorts them above everything and re-creates the defect as a fresh block. This
 * script is deterministic and idempotent: same catalog in, same numbering out.
 *
 *   node tools/reorder-feed.mjs                    # dry run — prints the plan
 *   node tools/reorder-feed.mjs --write            # wallpapers
 *   node tools/reorder-feed.mjs --write ringtones  # ringtones
 *
 * Does NOT bump content_version or rebuild — the caller does that, so a reorder
 * and a content publish can share one version bump:
 *   node tools/prod-sql.mjs --write "UPDATE app_config SET content_version = content_version + 1 WHERE id = 1"
 *   curl -X POST https://arul-api.hsrutility.com/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
 *
 * Connection string comes from workers/.dev.vars, never the CLI.
 */
import fs from "node:fs";
import postgres from "postgres";

const args = process.argv.slice(2);
const allowWrite = args.includes("--write");
const table = args.filter((a) => a !== "--write")[0] ?? "wallpapers";

if (!["wallpapers", "ringtones"].includes(table)) {
  console.error(`usage: node tools/reorder-feed.mjs [--write] [wallpapers|ringtones]`);
  process.exit(2);
}

const env = fs.readFileSync(new URL("../.dev.vars", import.meta.url), "utf8");
const url = env.match(/^DATABASE_URL=(.+)$/m)?.[1]?.trim();
if (!url) {
  console.error("DATABASE_URL not found in workers/.dev.vars");
  process.exit(1);
}

const sql = postgres(url, { ssl: "require", max: 1 });

try {
  // Newest-first WITHIN each category is the order each queue is drained in, so
  // the category chips keep their documented contract after the rewrite.
  const rows = await sql`
    SELECT id, category
    FROM ${sql(table)}
    WHERE is_published = true
    ORDER BY created_at DESC, id ASC
  `;

  if (rows.length === 0) {
    console.log(`[reorder] ${table}: nothing published`);
    process.exit(0);
  }

  // Queue per category, insertion order = newest-first.
  const queues = new Map();
  for (const r of rows) {
    if (!queues.has(r.category)) queues.set(r.category, []);
    queues.get(r.category).push(r.id);
  }

  // Deal biggest categories first each round. With unequal counts the largest
  // category inevitably tails the feed alone; leading with it keeps that tail as
  // short as possible.
  const cycle = [...queues.keys()].sort(
    (a, b) => queues.get(b).length - queues.get(a).length || a.localeCompare(b),
  );

  const ids = [];
  const cursor = new Map(cycle.map((c) => [c, 0]));
  while (ids.length < rows.length) {
    for (const c of cycle) {
      const q = queues.get(c);
      const i = cursor.get(c);
      if (i >= q.length) continue;
      ids.push(q[i]);
      cursor.set(c, i + 1);
    }
  }

  const ranks = ids.map((_, i) => i + 1);
  const byId = new Map(rows.map((r) => [r.id, r.category]));

  console.log(`[reorder] ${table}: ${rows.length} rows`);
  console.log(
    `[reorder] cycle: ${cycle.map((c) => `${c}(${queues.get(c).length})`).join(" → ")}`,
  );
  console.log(`[reorder] first 12: ${ids.slice(0, 12).map((id) => byId.get(id)).join(", ")}`);

  if (!allowWrite) {
    console.log("[reorder] DRY RUN — re-run with --write to apply");
    process.exit(0);
  }

  // One statement, so the feed never exists in a half-renumbered state.
  await sql`
    UPDATE ${sql(table)} AS t
    SET sort_order = d.rank
    FROM (
      SELECT unnest(${ids}::uuid[]) AS id, unnest(${ranks}::int[]) AS rank
    ) AS d
    WHERE t.id = d.id
  `;
  console.log(`[reorder] ${table}: sort_order rewritten 1..${rows.length}`);
  console.log("[reorder] now bump content_version and rebuild — see the header.");
} finally {
  await sql.end().catch(() => {});
}
