---
name: neon-migration
description: Write and apply a schema migration to prod Neon Postgres for Arul. Use for ANY DB schema/data change, and for the initial schema apply. psql is NOT installed — apply via workers/tools/prod-sql.mjs.
---

# Neon Migration

There is no `db/schema.sql` — the schema is **split across the numbered files in `db/schema/`**,
applied in filename order. Do not consolidate them; `pgserver.mjs` (verify-payments) and every fresh
install glob the directory.

**Fresh install:** every `db/schema/*.sql` in filename order, then `db/seed.sql`. The ringtones file
is **not optional**: build-catalog builds both scopes every hour (`allScopes`, build-catalog.ts:151).
A missing table does not crash the cron — the scope is caught and recorded as `{ error }` (`:254-256`),
and that one error then **withholds `catalog/version.json` for EVERY scope** (`:272`) and **skips the
canonical sweep** (`index.ts:201`). Wallpapers keep serving the previous `?v=`, so the whole catalog
freezes at the last good version with nothing but a `console.error` to show for it. The symptom to
look for is a version pointer that stops moving, never a loud failure.

## Changes after that

1. Write the change as idempotent SQL (`IF NOT EXISTS` / `IF EXISTS`) and put the END STATE in
   `db/schema/`, so it lands on **both** paths — a fresh install (files applied in order into an
   empty DB) and the live DB (one file applied on its own). `create table if not exists` is a NO-OP
   against an existing table, so editing a CREATE TABLE column list alone reaches fresh installs only.
   - **New table** → new `NN_short-name.sql`. One statement, both paths correct.
   - **New column** → new `NN_short-name.sql` holding `alter table … add column if not exists …`.
     This is the default and what `05_feed_rank.sql` / `06_popularity.sql` do: a fresh install runs
     the CREATE then the ALTER that adds the column, a live DB runs just the ALTER — same end state.
   - **Index** → `create index if not exists`, idempotent anywhere. **Constraint** → Postgres has no
     idempotent `ADD CONSTRAINT`; guard it (`do $$ … if not exists (select 1 from pg_constraint
     where conname=…) …`) or apply it once by hand. It is the same trap as the trigger below.
   - **Editing an existing file's CREATE TABLE list** is optional readability, never sufficient. Do
     it only if you ALSO append `alter table … add column if not exists …` in the same file — the
     double-write at `01_identity.sql:29` + `:32` (commit `b6287c9`). One without the other ships a
     column that exists on new databases and nowhere else.

   There is **no `db/migrations/` diary** — it was retired because it only ever held byte-copies of
   schema files: the schema files ARE the source of truth. Never recreate the directory. Every
   statement is idempotent **except one**: `01_identity.sql:60`'s `create trigger` (Postgres has no
   `IF NOT EXISTS` for triggers). Prod already has that trigger, and `sql.unsafe()` runs the file as
   a single simple query, so re-applying `01` fails at the trigger and **rolls back the whole file —
   nothing is applied**. Until it becomes `create or replace trigger`, apply changes to `01` as the
   individual statement, not the file.
2. **Get explicit user approval before running anything destructive (DROP / DELETE / ALTER-narrowing)
   on prod.**
3. Apply with `workers/tools/prod-sql.mjs`. It reads the connection string out of git-ignored
   `workers/.dev.vars` itself, so it never lands in shell history, and it refuses a write unless you
   pass `--write`:

   ```powershell
   # PowerShell (this repo's primary shell) — from workers/
   node tools/prod-sql.mjs --write ([IO.File]::ReadAllText((Resolve-Path ..\db\schema\<FILE>.sql)))
   ```
   ```bash
   # Git Bash / POSIX — from workers/
   node tools/prod-sql.mjs --write "$(cat ../db/schema/<FILE>.sql)"
   ```

   **Never `"$(cat …)"` in PowerShell.** `cat` is `Get-Content`, which returns `string[]`; `"$(…)"`
   joins it with spaces, so every newline vanishes and `prod-sql.mjs`'s `--` comment stripper — with
   no `\n` left to stop at — eats the ENTIRE file. Measured: `stripped_len 0`. An empty statement
   trips no usage guard, prints no warning, exits 0 and outputs `[]`, byte-identical to a successful
   apply. Never `Get-Content -Raw` without `-Encoding UTF8` either: PowerShell 5.1 decodes UTF-8 as
   single-byte chars, so a non-ASCII default or `check` constraint reaches prod as mojibake.
   **`[prod-sql] WRITING to production:` is the only signal anything is being applied — if you do
   not see it, nothing was applied, whatever the exit code says.** Step 4 is what catches it.

   Guards: any write without `--write` is refused outright, and an unqualified `UPDATE`/`DELETE` (no
   `WHERE`) is refused **as the first statement**. That second guard is not anchored per-statement,
   so a stacked `BEGIN; DELETE …; COMMIT;` slips past it — don't wrap a destructive change to buy
   safety it does not give. Multi-statement files are already atomic: `sql.unsafe()` runs them as one
   simple query, which Postgres executes in a single implicit transaction. SQL comments are stripped
   before execution, so keep meaning in the statements, not in `--` notes.

4. Confirm the new shape with the read-only helper (no flag, refuses writes and stacked statements):

   ```bash
   node tools/prod-query.mjs "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='subscriptions'"
   node tools/prod-query.mjs "SELECT indexname FROM pg_indexes WHERE tablename='wallpapers'"
   ```

   `wallpapers` / `ringtones` filter on **`is_published`**, not `published` — the wrong name raises
   `column "published" does not exist` wherever it appears, in a `WHERE` as much as in a `SELECT`.

5. Catalog-affected? Bump `content_version` and rebuild (content-ops skill) — the browse feed never
   reads the DB, so a schema change alone changes nothing users see.
6. Worker code depends on the change? Apply the migration FIRST, then deploy (deploy-worker skill).
