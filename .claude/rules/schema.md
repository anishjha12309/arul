---
description: Schema changes must be idempotent on both paths.
paths:
  - "db/schema/**"
  - "db/seed.sql"
  - "db/migrations/**"
---

There is no `db/schema.sql` — the schema is the numbered files in `db/schema/`, applied in filename
order, then `db/seed.sql`. Do not consolidate them; the test harness and every fresh install glob the
directory.

- **Write the END STATE into `db/schema/` as idempotent SQL** so it lands on BOTH paths: a fresh
  install (files applied in order into an empty DB) and the live DB (one file applied on its own).
  `create table if not exists` is a no-op against an existing table, so editing a CREATE TABLE column
  list alone reaches fresh installs only — a new column is a new numbered file holding
  `alter table … add column if not exists …`.
- **Postgres has no idempotent `ADD CONSTRAINT` and no `IF NOT EXISTS` for triggers.** Guard a
  constraint explicitly, and use `create or replace trigger`. A bare `create trigger` fails on a live
  DB, and because a file is sent as ONE simple query — which Postgres runs in a single implicit
  transaction — that failure **rolls back every other statement in the file**.
- **Get explicit user approval before running anything destructive on prod** (DROP / DELETE /
  ALTER-narrowing).
- **The column is `is_published`, not `published`** — the wrong name raises `column … does not exist`
  wherever it appears.
- **Retired columns stay.** `apply_score`/`set_score`/`scored_at` remain on both content tables and
  hold frozen data: unread, unwritten, and no migration drops them
  ([docs/browse.md](../../docs/browse.md)). `feed_rank` is NOT one of them any more — dropped
  2026-08-25, restored 2026-09-02 (`db/schema/11_feed_rank.sql`) as a nullable pin column the CMS
  writes and `build-catalog` sorts on first. Nullable is the feature: NULL means unpinned, so no
  default and no backfill, ever.
- A catalog-affecting change needs a `content_version` bump and a rebuild — the browse feed never
  reads the DB, so a schema change alone changes nothing users see. If Worker code depends on the
  change, apply the schema FIRST, then deploy.

Read [docs/data-model.md](../../docs/data-model.md); apply with the `neon-migration` skill, which
carries the `prod-sql.mjs` invocation traps.
