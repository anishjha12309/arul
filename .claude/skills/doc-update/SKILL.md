---
name: doc-update
description: Write the doc or rule update after the doc-sync hook names a file, or when adding, splitting or routing a doc in Arul. Covers the ROUTES table, .claude/rules, the byte budgets and the house style.
---

# Doc Update

The `[doc-sync]` reminder already named the file. Open it and edit it; do not scan `docs/` to work out
which doc covers the change — the route table exists so nobody has to.

Suspect an *existing* line is stale rather than missing? That is the read path: run `/doc-audit <doc>`
instead of editing from memory.

## Where a fact goes

**One home per fact**, pointers everywhere else. Three homes exist:

- **`docs/<area>.md`** — the trap, the evidence, the dead ends, the reasoning. The default home.
- **`.claude/rules/<area>.md`** — invariants only, for an area Claude edits. Injected when Claude reads
  a matching file, so it stays short and ends with the doc to read before changing the area. Every
  rule carries `paths:` frontmatter with narrow globs — a rule without `paths:` loads on every session
  like CLAUDE.md, and `lib/**` would load almost always.
- **`CLAUDE.md`** — only what every session needs regardless of what is being touched.

`docs/edge-cases.md` is an INDEX: one line per regression contract, no reasoning.
`docs/known-issues.md` holds open defects only — a fixed one is deleted, git has it.

## The two tables that stay in step

`.claude/hooks/doc-sync-reminder.js` → the `ROUTES` array: code-path globs → doc names, first match
wins, the catch-all `workers/src/lib/**` row LAST. Every routed area also has a `.claude/rules/` glob
covering the same paths, so the reminder and the injected rule agree.

- New documented area → a ROUTES row and a rule glob. **A doc nobody routes to goes stale: route it or
  do not create it.**
- Moved a file → fix its glob in both.

## Budgets — bytes, not lines

| File | Cap |
| --- | --- |
| `CLAUDE.md` | 6 KB |
| any `docs/*.md`, skill, agent, README or tools doc | 10 KB |
| any `.claude/rules/*.md` | 2.5 KB (injected on read) |
| a skill `description` | 250 chars, key use case first |

Wrap prose at ~110 characters. No bullet or paragraph over ~500 characters — longer is two facts or a
story. Past a cap, split the tail into a focused `docs/<topic>.md`, route it, and leave a one-line
pointer. Every file stands alone: an agent that opens only `docs/phonepe.md` must not need
`docs/architecture.md` to act.

```bash
for f in CLAUDE.md README.md workers/README.md docs/*.md .claude/rules/*.md \
  .claude/skills/*/*.md .claude/agents/*.md tools/content-import/*.md; do
  [ -f "$f" ] && printf "%6d %s\n" $(wc -c < "$f") "$f"; done | sort -n
```

## House style

- **Constraints only.** A line earns its place by encoding a trap paid for on device, a behaviour
  contract, an owner decision, or a dead end worth not repeating. Anything readable from the code or
  the running app — layouts, copy, feature descriptions, what-was-done-when — is not written down.
- **No calendar dates, no build numbers as timestamps, no done-logs, no diaries.** Provenance is
  `git log`. Keep only durations and clock values that ARE the rule (a 24 h notify window, a 21:30 UTC
  cron, a 6 h grace).
- **Imperative, WHY before WHAT.** "Budget SoCs fit ~2 decoder sessions, so cap the pool at 2" beats
  "cap the pool at 2": an agent who knows the constraint handles the case you did not write down.
- **Name the trap.** Which endpoint 401s, which flag returns 200 while doing nothing. A concrete
  curl, key or ffmpeg line beats a paragraph.
- **No padding.** No intro, no summary, no "this document describes", no "verify / double-check /
  make sure" (they breed over-verification loops). Cut any line whose deletion loses nothing.
- **A number that moves is not doc material** — conversion rates, install counts and measured
  baselines belong in a dashboard.

## Skip it when

The edit was a rename, a formatting pass, a type-only change, moved or restyled UI, a copy tweak, or a
fix that restores documented behaviour. The reminder is not an obligation — most edits deserve no doc
update at all.
