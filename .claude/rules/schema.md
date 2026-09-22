---
description: Schema changes must be idempotent on both paths.
paths:
  - "db/schema/**"
  - "db/seed.sql"
  - "db/migrations/**"
---

The schema is the numbered files in `db/schema/`, applied in filename order, then `db/seed.sql`. Do
not consolidate them; the test harness and every fresh install glob the directory.

- **Write the END STATE as idempotent SQL** so it lands on BOTH paths: a fresh install (all files, in
  order, into an empty DB) and the live DB (one file on its own). `create table if not exists` is a
  no-op on an existing table, so a new column is a NEW numbered file with
  `alter table … add column if not exists …`.
- **No idempotent `ADD CONSTRAINT`, no `IF NOT EXISTS` for triggers.** Guard a constraint explicitly;
  use `create or replace trigger`. A file is ONE simple query in one implicit transaction, so a bare
  `create trigger` failing **rolls back every other statement in the file**.
- **Explicit user approval before anything destructive on prod** (DROP / DELETE / ALTER-narrowing).
- **The column is `is_published`, not `published`.**
- **Retired columns stay**: `apply_score`/`set_score`/`scored_at` hold frozen data, unread, never
  dropped. `feed_rank` (`db/schema/11_feed_rank.sql`) is a live nullable pin column — NULL means
  unpinned, so no default and no backfill, ever.
- A catalog-affecting change needs a `content_version` bump and a rebuild — the feed never reads the
  DB. If Worker code depends on the change, apply the schema FIRST, then deploy.

Read [docs/data-model.md](../../docs/data-model.md); apply with the `neon-migration` skill, which
carries the `prod-sql.mjs` invocation traps.
