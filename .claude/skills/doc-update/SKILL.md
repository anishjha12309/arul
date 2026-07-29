---
name: doc-update
description: Write the doc update after the doc-sync hook names a file, or when adding/splitting a doc in Arul. Covers the route table, the house style, and the 100-line rule.
---

# Doc Update

The `[doc-sync]` reminder already named the file. Open that file and edit it. Do not scan `docs/` to work out which doc covers the change — that is what the table exists to prevent.

## The route table

`.claude/hooks/doc-sync-reminder.js` → the `ROUTES` array at the top. Code path globs → doc names, first match wins.

- Add a new documented area? Add a row. Move a file? Fix its glob.
- A new doc nobody routes to will go stale — route it or don't create it.
- Sibling repo: `c:\Anish\Pakiza\.claude\hooks\doc-sync-reminder.js` has its own table over its own docs.

## House style

Write the way the codebase's docs already read. Six rules:

**Imperative, not descriptive.** The doc is an instruction to the next agent, not a description of the system.
> before: `Media is served from R2 because egress is free.`
> after: `Serve media from R2 — zero egress is what makes this affordable.`

**Constraint first, rule second.** Lead with WHY the rule exists; an agent that knows the constraint handles the case you didn't write down. "Budget SoCs fit ~2 decoder sessions, so cap the pool at 2" beats "cap the pool at 2".

**Show, don't tell, when a rule is fiddly.** A concrete curl, key, or ffmpeg line beats a paragraph describing it.

**Name the trap.** Write the specific thing that broke: which endpoint 401s, which flag returns 200 while doing nothing, which date it cost a build. Vague caution teaches nothing.

**No padding.** No intro paragraph, no "Summary" repeating the section above, no "this document describes…". Cut any line whose deletion loses no information.

**Never write "verify your work", "double-check", or "make sure to confirm".** These produce over-verification loops. State the rule; trust it.

## 100-line rule

**No doc file over 100 lines** (top-level `README.md` exempt). Past 100, split the tail into a focused `docs/<topic>.md` and leave a one-line pointer saying when to read it:

```
Cache headers, the two zone rules, and the measurement trap: [caching.md](caching.md) — read before changing any Cache-Control.
```

Every file must stand alone. An agent that opens only `docs/phonepe.md` must not need `docs/architecture.md` to act.

`CLAUDE.md` has its own cap (stated in its Meta section) — respect it; overflow goes to `docs/` and gets linked from the section it left.

## Peers rule

Arul and Pakiza are peers with near-identical backends. Worker routes, entitlement, crons, catalog build, PhonePe, R2 conventions, and analytics gating are **shared behaviour** — a fact learned in one repo is true in the other.

When the change touches shared logic:

1. Update this repo's doc.
2. Update the sibling's equivalent doc (`c:\Anish\Pakiza\docs\`). The names differ — `cron.md` + `caching.md` here are `catalog-and-cron.md` there; `edge-cases.md` here is `platform-gotchas.md` there; `provisioning.md` has no Pakiza twin (it lives in `workers/README.md` + CLAUDE.md §8).
3. Can't do (2) this session? Add a one-line entry under `## Open` in `c:\Anish\Pakiza\docs\known-issues.md` naming the fact and the doc that needs it.

App-layer UI, theming, localization, and the category browse axis are **not** shared — that axis is a deliberate delta from Pakiza's type-based browse. Don't cross-post those.

## Skip it when

The edit was a rename, a formatting pass, a type-only change, or a fix that restores documented behaviour rather than changing it. The reminder is not an obligation.
