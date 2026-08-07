---
name: neon-migration
description: Write and apply a schema migration to prod Neon Postgres for Arul. Use for ANY DB schema/data change, and for the initial schema apply. psql is NOT installed — apply via workers/tools/prod-sql.mjs.
---

# Neon Migration

There is no `db/schema.sql` — the schema is **split across the numbered files in `db/schema/`**,
applied in filename order. Do not consolidate them; `pgserver.mjs` (verify-payments) and every fresh
install glob the directory.

**Fresh install:** every `db/schema/*.sql` in filename order, then `db/seed.sql`. The ringtones file
is **not optional** — build-catalog queries the ringtones scope every hour and crash-loops against a
missing table.

## Changes after that

1. Write the change as idempotent SQL (`IF NOT EXISTS` / `IF EXISTS`; wrap multi-statement changes
   in `BEGIN; … COMMIT;`) and put the END STATE in `db/schema/` — a new table is a new
   `NN_short-name.sql`, an altered table is an edit to its existing file. There is **no
   `db/migrations/` diary** (retired 2026-08-07 — it only ever held byte-copies of schema files):
   the schema files ARE the source of truth, and because every statement is idempotent, applying the
   schema file IS the migration.
2. **Get explicit user approval before running anything destructive (DROP / DELETE / ALTER-narrowing)
   on prod.**
3. Apply with `workers/tools/prod-sql.mjs`. It reads the connection string out of git-ignored
   `workers/.dev.vars` itself, so it never lands in shell history, and it refuses a write unless you
   pass `--write`:

   ```bash
   cd workers
   node tools/prod-sql.mjs --write "$(cat ../db/schema/<FILE>.sql)"
   ```

   Two guards you will hit rather than read about: an unqualified `UPDATE`/`DELETE` (no `WHERE`) is
   refused **even with `--write`**, and any write without the flag is refused outright. Both are
   deliberate — rewrite the statement, never the tool. SQL comments are stripped before execution,
   so keep meaning in the statements, not in `--` notes.

4. Confirm the new shape with the read-only helper (no flag, refuses writes and stacked statements):

   ```bash
   node tools/prod-query.mjs "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='subscriptions'"
   node tools/prod-query.mjs "SELECT indexname FROM pg_indexes WHERE tablename='wallpapers'"
   ```

   `wallpapers` / `ringtones` filter on **`is_published`**, not `published` — a query on the wrong
   name returns an error, but a `WHERE` on it in a migration would silently match nothing.

5. Catalog-affected? Bump `content_version` and rebuild (content-ops skill) — the browse feed never
   reads the DB, so a schema change alone changes nothing users see.
6. Worker code depends on the change? Apply the migration FIRST, then deploy (deploy-worker skill).
