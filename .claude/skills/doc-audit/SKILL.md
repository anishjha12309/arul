---
name: doc-audit
description: Adversarially audit Arul docs against code, Neon, wrangler and the live API — a prover evidences each claim, a denier refutes it. Use when a doc may be stale, or before trusting one for a risky change. /doc-audit sweeps all; /doc-audit phonepe picks.
disable-model-invocation: true
---

# Doc Audit — prover vs denier

Docs must match the code, Neon and Cloudflare — not the reverse — EXCEPT where a doc encodes an owner
decision, in which case reality must match the doc. One adversarial pair per doc: `doc-prover` grounds
every claim in primary sources, `doc-denier` default-denies and refutes with counter-evidence. Never
speculative — every verdict but UNVERIFIED carries a citation: REFUTED and CONTESTED cite the denier's
counter-source, CONFIRMED countersigns the prover's, or the denier's own when hunting turned it up.

## Scope

Args name docs (`phonepe` → `docs/phonepe.md`); no args = full sweep — every tracked markdown the
repo asks an agent to TRUST, in three tiers: the routed core (`docs/*.md`, `CLAUDE.md`,
`workers/README.md`) · the procedures (`README.md`, `tools/content-import/*.md`) · the instructions
that RUN (`.claude/skills/*/SKILL.md`, `.claude/agents/*.md`, `.claude/rules/*.md`) — stale text in
that last tier is EXECUTED, not merely read, so it is the highest-consequence tier. ~2–3 Opus runs
per doc: state the cost first, and keep **≤4 subagents in flight** — wider
hits the session limit and kills the run mid-pair, losing unpaired dossiers.

## The claim compact (decides what a REFUTED verdict does)

| Type | Meaning | On REFUTED |
| --- | --- | --- |
| DESCRIPTIVE | Doc describes reality | Fix the doc, working tree only |
| NORMATIVE | Doc IS the contract (owner calls, "never", deliberate deltas, security invariants) | Flag the CODE/infra to the user — never edit the doc side |
| EXTERNAL | Vendor behaviour / on-device history | Settle against CURRENT vendor docs, fetched live — never from model memory; on REFUTED see step 4 (API surface only) |

UNVERIFIED is never treated as stale. The paid-for traps (PhonePe quirks, decoder limits)
are the docs' whole value; the audit protects them from contradiction, it does not shred
them for lacking lab proof. Vendor docs contradicting an on-device trap → CONTESTED (the
trap often exists because reality diverges from the docs); vendor docs refute outright only
the vendor's own API surface — endpoint names, params, deprecations, documented limits.

## Read-only rules (go verbatim into both agents' task prompts)

Any command that cannot mutate is in scope — the list below is the tools you need, not the boundary.
The boundary is the Forbidden list plus the categories: SELECT-only SQL, GET/HEAD-only HTTP, wrangler
read subcommands (`list`/`get`/`view`/`whoami`/`--help`, never `deploy`/`put`/`delete`/`create`/
`rollback`/`triggers`/`versions upload`), plain repo reads. A read-only command merely missing from
the list is fine to run and is NEVER a reason to write NONE FOUND.

- `node workers/tools/prod-query.mjs "SELECT ..."` — the ONLY Neon tool an audit may run; it refuses
  non-SELECT, multi-statement and write keywords (guard at `workers/tools/prod-query.mjs:32-44`)
- In `workers/`: `npx wrangler deployments list` · `secret list` (names only) · `kv namespace list` ·
  `kv key list --namespace-id <id>` · `r2 bucket list`
- `curl -s`/`curl -sI` GET/HEAD against `arul-api.hsrutility.com` and `arul-cdn.hsrutility.com`
- Vendor docs, EXTERNAL claims only: WebSearch, then `trafilatura -u "<URL>" --markdown | head -150`
  (WebFetch is denied globally). Official portals only: developer.phonepe.com, developers.google.com,
  firebase.google.com/docs, posthog.com/docs, developers.cloudflare.com, pub.dev.

Forbidden always: **`node workers/tools/prod-sql.mjs` — flag or no flag** (its name advertises a
read, but it CAN WRITE and one `--write` makes it one) · `wrangler deploy`, `secret put|bulk`,
`kv key put|delete`, any R2 write, cache purge, `POST /internal/build-catalog`, any HTTP
POST/PUT/DELETE, any SQL that mutates.

**Never execute a procedure to verify it.** Auditing a doc that documents a deploy, a prod write, an
R2 mutation, a signed build or a payment means READING the code that implements it. Running it to see
what happens is the one shortcut that can do real damage — and the tier-three docs are all procedures.

## Procedure

1. Resolve targets. For each doc spawn `doc-prover` (Agent tool, background, ≤4 in flight): task = doc
   path + the read-only rules above + "return the dossier format from your definition".
2. When a prover's dossier arrives, spawn `doc-denier` for that doc with the full dossier pasted in,
   plus the read-only rules.
3. If the denier returns `CHALLENGES`, SendMessage the SAME prover with only the challenged claim ids
   and the denier's counter-evidence, then SendMessage the SAME denier with the rebuttal for final
   verdicts. Exactly one round — after it, verdicts are final.
4. Resolve verdicts:
   - `REFUTED` + DESCRIPTIVE → edit the doc now, per the doc-update skill's house style (constraints
     only · imperative · WHY then WHAT · name the trap · the BYTE budgets). Replace the wrong fact with
     the evidenced one; keep the WHY if it survives.
   - `REFUTED` + NORMATIVE → report entry: contract, violating file:line, denier's evidence. No edit
     on either side without the user.
   - `REFUTED` + EXTERNAL → the vendor's documented API surface won. Fix the doc now, working tree
     only, and carry the fetched URL into the line so the next audit does not re-derive it. Correct
     ONLY the API-surface half: if the line welds a vendor fact to an on-device trap, split it — the
     trap stays, untouched and unshortened. Never edit code/infra on an EXTERNAL refutation; a vendor
     doc is evidence about the vendor, not about this repo.
   - `CONTESTED` → report entry with both citations · `UNVERIFIED` → report appendix line. No edit.
   - `ECHO-FINDINGS` → when echoes disagree, the one matching source evidence wins; fix the others as
     DESCRIPTIVE drift (CLAUDE.md and `.claude/rules/` included, respecting their byte budgets).
5. Never commit. Never run a write against prod. Doc edits stay in the working tree for the user.

## Report

Write `doc-audit-<yyyy-mm-dd>.md` to the scratchpad: verdict counts per doc, every REFUTED with its
evidence pair, CONTESTED, echo findings, UNVERIFIED appendix. The chat summary leads with the two
lists that need the user — NORMATIVE violations and CONTESTED claims — then the doc fixes applied.

## Boundaries

- Reads Pakiza only if a claim explicitly names it; auditing Pakiza's docs is that repo's job (copy
  this skill + agents there when ready).
- The doc-sync hook is the write path (code changed → update doc); this skill is the read path (does
  the doc still tell the truth). Neither replaces the other, and both now cover the same tree.
