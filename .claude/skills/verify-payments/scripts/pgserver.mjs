/**
 * Embedded Postgres for the payment harness.
 *
 * Speaks the real PG wire protocol on 127.0.0.1:5433 so `wrangler dev` can bind
 * its HYPERDRIVE binding to it. Loads db/schema/*.sql in filename order, so every
 * table, index, constraint and trigger matches production exactly.
 *
 * Nothing here ever touches Neon. That is the point: the harness seeds
 * subscription rows with a past next_debit_at, which in production would make
 * the deployed hourly cron pick them up and fire real PhonePe calls.
 *
 * Data lives in ./pgdata (git-ignored). Delete that directory to reset.
 *
 *   node pgserver.mjs [--reset]
 */
import { PGlite } from "@electric-sql/pglite";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";
import { readFileSync, readdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../../..");
const schemaDir = resolve(repoRoot, "db/schema");
const dataDir = resolve(here, "pgdata");

if (process.argv.includes("--reset")) {
  rmSync(dataDir, { recursive: true, force: true });
  console.log("[pg] wiped", dataDir);
}

const db = await PGlite.create({ dataDir });

// Load the schema only into a FRESH dataDir. db/schema/*.sql is not re-runnable:
// its tables/indexes use `if not exists`, but `create trigger` does not accept
// that clause, so a second run dies on
//   trigger "subscriptions_set_updated_at" for relation "subscriptions" already exists
// and the harness never reaches listen. Restarting must be free (the pgdata
// directory is the whole point of persisting between scenarios), so skip the
// load when the schema is already there. `--reset` forces a clean rebuild.
const initialized = await db.query(
  "select 1 from information_schema.tables where table_schema='public' and table_name='subscriptions'",
);
if (initialized.rows.length === 0) {
  for (const file of readdirSync(schemaDir).filter((f) => f.endsWith(".sql")).sort()) {
    await db.exec(readFileSync(resolve(schemaDir, file), "utf8"));
  }
  console.log("[pg] schema created from db/schema/*.sql");
} else {
  console.log("[pg] existing schema reused (pass --reset to rebuild)");
}

const tables = await db.query(
  "select table_name from information_schema.tables where table_schema='public' order by 1",
);
console.log("[pg] tables:", tables.rows.map((r) => r.table_name).join(", "));

const server = new PGLiteSocketServer({ db, port: 5433, host: "127.0.0.1" });
await server.start();
console.log("[pg] listening on 127.0.0.1:5433");

const shutdown = async () => {
  await server.stop();
  await db.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
