---
description: Node scripts and hooks — ESM, deps, flags, exit codes, credentials, read-only prod.
paths:
  - "tools/**/*.mjs"
  - "tools/**/*.js"
  - "workers/tools/**"
  - ".claude/hooks/**"
  - ".claude/skills/**/scripts/**"
---

These run on a developer machine only. Biome covers them (`npm run check` in `workers/`); comments:
[comments.md](comments.md).

- **A new script is ESM `.mjs`.** Root `tools/` has no `package.json`: borrow a dependency through
  `createRequire` from `workers/` (typescript) or the CMS checkout (sharp), as the neighbours do.
  `workers/tools/*.mjs` run from `workers/` (`cd workers && node tools/x.mjs`) so `postgres` resolves.
- **Hooks stay CommonJS `.js`.** `run.js` `require()`s each module, and with no `package.json` above
  them Node reads `.js` as CommonJS. A hook runs in the tool's cwd (often `workers/`), so resolve repo
  paths from `CLAUDE_PROJECT_DIR`, falling back to `__dirname/../..`. Contract, fail-open, probe:
  [hooks-release.md](hooks-release.md).
- **Parse flags with `util.parseArgs`** (Node docs; `strict` throws on an unknown flag). The older
  scripts test `argv.includes("--dry-run")`, where a typo like `--dryrun` runs the real write.
- **Exit 2 = could not run** (usage, missing file or credential), **1 = ran and failed or refused**,
  0 = clean. After printing a result set `process.exitCode`: `process.exit()` drops stdout still being
  written (Node docs; pipe writes are async).
- **A credential never rides argv**, where it lands in shell history and the transcript. Read it by
  NAME from `workers/.dev.vars` (`workers/tools/lib/neon-branch.mjs`) or from an `--env-file` path:
  `.dev.vars` holds four postgres strings and the first is the debug branch, so "the first
  `postgres://`" reads the wrong database. Print which one opened.
- **Production is read-only by default.** `prod-query.mjs` runs one SELECT/WITH and its guard is the
  security boundary behind a permission allow-rule; writes go through `prod-sql.mjs --write`, which
  refuses an UPDATE/DELETE without WHERE. A new prod script reads unless a write flag says otherwise.
- **The local-stack tools (`workers/tools/local-*`) touch the debug branch and local R2 only**, through
  `local-lib.mjs`'s fail-closed guards; a new one imports them ([docs/local-stack.md](../../docs/local-stack.md)).
