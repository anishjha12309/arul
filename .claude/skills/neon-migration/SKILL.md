---
name: neon-migration
description: Write and apply a schema migration to prod Neon Postgres for Arul. Use for ANY DB schema/data change, and for the initial schema apply. psql is NOT installed — apply via workers/tools/prod-sql.mjs.
---

# Neon Migration

There is no `db/schema.sql` — the schema is **split across `db/schema/01→04`**, applied in filename
order. Do not consolidate them; `pgserver.mjs` (verify-payments) and every fresh install read the
directory.

**Fresh install:** `01_identity.sql` → `02_content.sql` → `03_referral_config.sql` →
`04_ringtones.sql` → `db/seed.sql`. **04 is not optional** — build-catalog queries the ringtones
scope every hour and crash-loops against a missing table, even though the app's ringtones tab is
parked.

## Changes after that

1. Write `db/migrations/YYYY-MM-DD_short-name.sql`. Idempotent only (`IF NOT EXISTS` / `IF EXISTS`);
   wrap multi-statement changes in `BEGIN; … COMMIT;`.
2. Mirror the end-state into `db/schema/` — that directory is the source of truth for fresh installs,
   and a migration that isn't mirrored silently stops existing after the next clean setup.
3. **Get explicit user approval before running anything destructive (DROP / DELETE / ALTER-narrowing)
   on prod.**
4. Apply with `workers/tools/prod-sql.mjs`. It reads the connection string out of git-ignored
   `workers/.dev.vars` itself, so it never lands in shell history, and it refuses a write unless you
   pass `--write`:

   ```bash
   cd workers
   node tools/prod-sql.mjs --write "$(cat ../db/migrations/<FILE>.sql)"
   ```

   Two guards you will hit rather than read about: an unqualified `UPDATE`/`DELETE` (no `WHERE`) is
   refused **even with `--write`**, and any write without the flag is refused outright. Both are
   deliberate — rewrite the statement, never the tool. SQL comments are stripped before execution,
   so keep meaning in the statements, not in `--` notes.

5. Confirm the new shape with the read-only helper (no flag, refuses writes and stacked statements):

   ```bash
   node tools/prod-query.mjs "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='subscriptions'"
   node tools/prod-query.mjs "SELECT indexname FROM pg_indexes WHERE tablename='wallpapers'"
   ```

   `wallpapers` / `ringtones` filter on **`is_published`**, not `published` — a query on the wrong
   name returns an error, but a `WHERE` on it in a migration would silently match nothing.

6. Catalog-affected? Bump `content_version` and rebuild (content-ops skill) — the browse feed never
   reads the DB, so a schema change alone changes nothing users see.
7. Worker code depends on the change? Apply the migration FIRST, then deploy (deploy-worker skill).
