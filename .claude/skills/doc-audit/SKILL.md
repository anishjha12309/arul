---
name: doc-audit
description: Adversarial audit of Arul docs against code, Neon schema, wrangler config, and the live API — a prover agent must evidence every claim, a denier agent tries to refute it. Use when a doc may be stale, before trusting a doc for a risky change, or on demand — /doc-audit for a full sweep, /doc-audit phonepe cron for specific docs. Read-only against prod; fixes descriptive drift in the working tree, flags contract violations.
---

# Doc Audit — prover vs denier

Docs must match the code, Neon, and Cloudflare — not the other way around — EXCEPT where a
doc encodes an owner decision, in which case reality must match the doc. The audit runs one
adversarial pair per doc: `doc-prover` grounds every claim in primary sources, `doc-denier`
default-denies and refutes with counter-evidence. Nothing here is speculative review — every
verdict but UNVERIFIED carries a citation: REFUTED and CONTESTED cite the denier's
counter-source, CONFIRMED countersigns the prover's — or the denier's own, when hunting
turned it up.

## Scope

Args name docs (`phonepe` → `docs/phonepe.md`); no args = full sweep: every `docs/*.md`,
`CLAUDE.md`, `workers/README.md`. A full sweep is ~2–3 Opus subagent runs per doc across
~16 docs — state that cost in one sentence before launching it.

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

Any command that cannot mutate is in scope — the list below is the tools you will need, not the
boundary. The boundary is the Forbidden list plus the categories: SELECT-only SQL, GET/HEAD-only
HTTP, wrangler read subcommands (`list`/`get`/`view`/`whoami`/`--help`, never `deploy`/`put`/
`delete`/`create`/`rollback`/`triggers`/`versions upload`), and plain repo reads (`ls`, `wc -l`,
`git ls-files|log|show`, `grep`). A read-only command missing from the list is fine to run and is
NEVER a reason to write NONE FOUND.

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

## Procedure

1. Resolve targets. For each doc spawn `doc-prover` (Agent tool, background, ≤4 in flight):
   task = doc path + the read-only rules above + "return the dossier format from your definition".
2. When a prover's dossier arrives, spawn `doc-denier` for that doc with the full dossier
   pasted in, plus the read-only rules.
3. If the denier returns `CHALLENGES`, SendMessage the SAME prover agent with only the
   challenged claim ids and the denier's counter-evidence; then SendMessage the SAME denier
   with the rebuttal for final verdicts. Exactly one round — after it, verdicts are final.
4. Resolve verdicts:
   - `REFUTED` + DESCRIPTIVE → edit the doc now, per the doc-update skill's house style
     (constraints only · imperative · WHY then WHAT · name the trap · 100-line cap). Replace
     the wrong fact with the evidenced one; keep the WHY if it survives.
   - `REFUTED` + NORMATIVE → report entry: contract, violating file:line, denier's evidence.
     No edit on either side without the user.
   - `REFUTED` + EXTERNAL → the vendor's own documented API surface won. Fix the doc now,
     working tree only, and carry the fetched URL into the line so the next audit does not
     re-derive it. Correct ONLY the API-surface half: if the line welds a vendor fact to an
     on-device trap, split it — the trap stays, untouched and unshortened. Never edit
     code/infra on an EXTERNAL refutation; a vendor doc is evidence about the vendor, not
     about this repo.
   - `CONTESTED` → report entry with both citations. No edit.
   - `UNVERIFIED` → report appendix line. No edit.
   - `ECHO-FINDINGS` → when echoes disagree, the one matching source evidence wins; fix the
     others as DESCRIPTIVE drift (CLAUDE.md included, respecting its 100-line meta rule).
5. Never commit. Never run a write against prod. Doc edits stay in the working tree for the
   user to review and commit.

## Report

Write `doc-audit-<yyyy-mm-dd>.md` to the scratchpad: verdict counts per doc, every REFUTED
with its evidence pair, CONTESTED, echo findings, UNVERIFIED appendix. The chat summary
leads with the two lists that need the user: NORMATIVE violations and CONTESTED claims,
then the doc fixes applied.

## Boundaries

- The audit reads Pakiza only if a claim explicitly names it; auditing Pakiza's docs is that
  repo's job (copy this skill + agents there when ready).
- The doc-sync hook remains the write path (code changed → update doc); this skill is the
  read path (does the doc still tell the truth). Neither replaces the other.
