---
name: doc-update
description: Write the doc or rule update after the doc-sync hook names a file, or when adding, splitting or routing a doc in Arul. Covers the ROUTES table, .claude/rules, the byte budgets and the house style.
---

# Doc Update

The `[doc-sync]` reminder already named the file. Open that file and edit it. Do not scan `docs/` to
work out which doc covers the change — that is what the route table exists to prevent.

Suspect an *existing* line is stale rather than missing? That is the read path — run
`/doc-audit <doc>` (an adversarial prover/denier check against code, Neon and wrangler) instead of
editing from memory.

## Where a fact goes

**One home per fact**, with pointers from everywhere else. Three places can hold it:

- **`docs/<area>.md`** — the narrative: the trap, the evidence, the dead ends, the reasoning. This is
  the default home.
- **`.claude/rules/<area>.md`** — the invariants only, for an area Claude edits. Injected when Claude
  reads a matching file, so it must stay short and must end with the doc to read before changing the
  area. **Every rule file MUST carry `paths:` frontmatter** — one without it loads on EVERY session
  exactly like CLAUDE.md, which defeats the point. Keep the globs narrow: `lib/**` or `workers/**`
  would load almost always.
- **`CLAUDE.md`** — only what every session needs regardless of what is being touched.

`docs/edge-cases.md` is an INDEX, not a home: one line per regression contract, no reasoning.

## The two tables that must stay in step

`.claude/hooks/doc-sync-reminder.js` → the `ROUTES` array at the top. Code-path globs → doc names,
first match wins; the catch-all `workers/src/lib/**` row stays LAST.

- Add a new documented area? Add a ROUTES row **and** a `.claude/rules/` glob covering the same
  paths, so the reminder and the injected rule agree.
- Move a file? Fix its glob in both.
- **A new doc nobody routes to will go stale** — route it, add it to CLAUDE.md §9, or don't create it.
- Sibling repo: Pakiza has its own table over its own docs.

## Budgets — bytes, not lines

The 100-line rule is retired; a line-count target just encourages long lines.

| File | Cap |
| --- | --- |
| `CLAUDE.md` | 8 KB |
| any `docs/*.md`, skill, agent, README or tools doc | 10 KB |
| any `.claude/rules/*.md` | 2 KB (it is injected on read) |
| a skill's `description` | 250 chars, key use case first |

Wrap prose at about 110 characters. No bullet or paragraph over ~500 characters — anything longer is
either two facts or a story. Past a cap, split the tail into a focused `docs/<topic>.md`, give it a
ROUTES row and a CLAUDE.md §9 entry, and leave a one-line pointer saying when to read it.

Every file must stand alone: an agent that opens only `docs/phonepe.md` must not need
`docs/architecture.md` to act.

```bash
for f in CLAUDE.md README.md workers/README.md docs/*.md .claude/rules/*.md \
  .claude/skills/*/*.md .claude/agents/*.md tools/content-import/*.md; do
  [ -f "$f" ] && printf "%6d %s\n" $(wc -c < "$f") "$f"; done | sort -n
```

## House style

**Constraints only.** A line earns its place by encoding a trap paid for on device, a behaviour
contract, or a dead end worth not repeating. Anything readable from the code or the running app —
layouts, positions, copy, feature descriptions, what-was-done-when — does not get written down.

**No calendar dates, ever.** Provenance lives in `git log`. Keep only durations and clock values that
ARE the rule (a 24 h notify window, a 21:30 UTC cron, a 6 h grace). A build number used as a
timestamp ("build 56 adds…") is a date. **No done-logs and no diaries.**

**Imperative, not descriptive.** The doc instructs the next agent; it does not describe the system.
> before: `Media is served from R2 because egress is free.`
> after: `Serve media from R2 — zero egress is what makes this affordable.`

**Constraint first, rule second.** Lead with WHY; an agent who knows the constraint handles the case
you did not write down. "Budget SoCs fit ~2 decoder sessions, so cap the pool at 2" beats "cap the
pool at 2".

**Show, don't tell, when a rule is fiddly.** A concrete curl, key or ffmpeg line beats a paragraph.

**Name the trap.** Write the specific thing that broke: which endpoint 401s, which flag returns 200
while doing nothing. Vague caution teaches nothing.

**No padding.** No intro paragraph, no "Summary" repeating the section above, no "this document
describes…". Cut any line whose deletion loses no information.

**Never write "verify your work", "double-check" or "make sure to confirm".** These produce
over-verification loops. State the rule; trust it.

**A number that moves is not doc material.** Conversion rates, install counts and measured baselines
belong in a dashboard, not here.

## Peers rule

Arul and Pakiza are peers with near-identical backends. Worker routes, entitlement, crons, catalog
build, PhonePe, R2 conventions and analytics gating are **shared behaviour** — a fact learned in one
repo is true in the other.

When the change touches shared logic: update this repo's doc, then the sibling's equivalent. The
names differ — `cron.md` and `caching.md` here are `catalog-and-cron.md` there; `edge-cases.md` here
is `platform-gotchas.md` there; `phonepe.md`, `analytics-events.md`, `architecture.md`,
`data-model.md`, `media-conventions.md` and `known-issues.md` share a name. `analytics-ops.md` has
**no Pakiza twin** — fold its material into that repo's `docs/analytics-events.md`. Infrastructure
facts get no doc of their own in either repo: the binding lives beside its comment in
`workers/wrangler.toml`, the secret in `workers/README.md §Secrets`, the console step in the skill
that needs it. Can't do the sibling this session? Add a one-line entry under `## Open` in
`c:\Anish\Pakiza\docs\known-issues.md` naming the fact and the doc that needs it.

App-layer UI, theming, localization and the category browse axis are **not** shared — that axis is a
deliberate delta from Pakiza's recency tabs. Don't cross-post those.

## Skip it when

The edit was a rename, a formatting pass, a type-only change, moved or restyled UI, a copy tweak, or
a fix that restores documented behaviour rather than changing it. The reminder is not an obligation —
most edits deserve no doc update at all.
