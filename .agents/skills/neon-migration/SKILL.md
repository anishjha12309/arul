---
name: neon-migration
description: Write and apply a schema migration to prod Neon Postgres for Arul. Use for ANY DB schema/data change, and for the initial schema apply. psql is NOT installed — applies via node+postgres.js.
---

# Neon Migration

**Fresh install:** apply `db/schema/01_identity.sql` → `02_content.sql` → `03_referral_config.sql`
→ `db/seed.sql`, in that order, via the runner below.

**Changes after that:**
1. Write `db/migrations/YYYY-MM-DD_short-name.sql`. Idempotent only (`IF NOT EXISTS` / `IF EXISTS`);
   wrap multi-statement changes in `BEGIN; … COMMIT;`.
2. Mirror the end-state in `db/schema/` — it is the source of truth for fresh installs.
3. **Get explicit user approval before running anything destructive (DROP/DELETE/ALTER-narrowing) on prod.**
4. Apply (no psql on this machine; `DATABASE_URL` lives in git-ignored `workers/.dev.vars`):
   ```bash
   cd workers && node -e "
   import('postgres').then(async ({default: postgres}) => {
     const sql = postgres(process.env.DATABASE_URL, { max: 1 });
     await sql.file('../db/migrations/<FILE>.sql');
     console.log('applied'); await sql.end();
   })"
   ```
5. Verify: query `information_schema.columns` / `pg_indexes` for the changed object.
6. Catalog-affected? Bump `content_version` + rebuild (see content-ops skill).
7. Worker code depends on the change? Deploy AFTER the migration is applied (deploy-worker skill).
