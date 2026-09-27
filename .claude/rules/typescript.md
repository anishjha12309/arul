---
description: Worker TypeScript — handler shape, error envelope, postgres.js traps, runtime limits, tests.
paths:
  - "workers/src/**"
  - "workers/test/**"
---

Biome formats and lints: `npm run check` / `npm run fix` in `workers/`. Comments:
[comments.md](comments.md). Crons and `wrangler.toml`: [worker-infra.md](worker-infra.md).

- **A route is `handleX(c: Context<{ Bindings: Env }>)` in `src/routes/<area>.ts`, registered in
  `src/index.ts`.** A detached handler cannot infer path params (Hono best practices), so
  `c.req.param()` takes a `?? ""`. Routes and crons import `lib/` and `env.ts`, never each other.
- **Every error is `{ error: { code, message } }` from the module's `errorResponse`.** The app reads
  `code` only (`api_client.dart`), so renaming a code breaks fielded builds. A body is untrusted:
  `c.req.json()` in try/catch → 400 `invalid_body`, then `typeof` each field.
- **postgres.js** (README): SQL is a `sql` tagged template, never a built string; `sql.unsafe` lives
  only behind the guard in `tools/prod-*.mjs`. A query runs once awaited or chained, and Biome cannot
  see postgres types, so a bare `` sql`…` `` never runs. `undefined` throws: bind `?? null`. Inside
  `sql.begin(async (tx) => …)` use `tx` only; the outer `sql` may be another pooled connection.
- **A route frees its client with `c.executionCtx.waitUntil(sql.end())` in `finally`,** chained after
  any unawaited write (`routes/media.ts`): two `waitUntil`s run in no fixed order.
- **Never bind a JS array.** `fetch_types: false` leaves no array serializer, so it arrives comma-joined
  and Postgres rejects it: `toPgTextArray(xs)` with an explicit `::text[]` cast (`lib/db.ts`).
- **Work after the response goes to `waitUntil()`; the rest is awaited** — the isolate can end before
  a floating promise settles (Cloudflare best practices).
- **Module scope holds only cross-request caches of public data** (the Google JWKS): isolates are
  reused, so request state there leaks into the next request.
- **Compare a bearer secret with `timingSafeEqual`** (`routes/internal.ts`), never `===`.
- **Tests run in Node on happy-dom, not workerd** (`vitest.config.ts`): a missing binding, compat flag
  or workerd-only API passes them; read `npx wrangler deploy --dry-run`. Each file mocks
  `../src/lib/db.js` to return `env._testSql` (`test/_ctx.ts`), which answers every query with the
  same rows; per-query answers need a routed mock (`routedSql`, `test/auth.test.ts`).
