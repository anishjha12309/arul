---
description: What a code comment may say, and how to cull one safely.
paths:
  - "lib/**"
  - "test/**"
  - "workers/**"
  - "android/**"
  - "db/**"
  - "tools/**"
  - ".claude/hooks/**"
  - "pubspec.yaml"
---

Code says what; git says when. A comment that repeats either rots the day the code moves.

**Write only a why** — the constraint, trap or decision that makes the code look odd, wasteful or
wrong without it. "Budget SoCs fit ~2 decoders, so the pool caps at 2" is a why.

- Three lines at most. Longer belongs in `docs/<area>.md`; leave a one-line pointer.
- `///` (Dart) or `/** */` (Kotlin, TS) is one line, only on a declaration another feature imports,
  saying what the signature does not.
- Never a banner or divider, never commented-out code, never a comment a good name would replace.
- No history: no dates, build numbers, names, "used to", "no longer". A history word inside a why
  ("no longer polls because Play throttles it") is fine.
- A TODO carries an owner or a reason.

**Deleting existing comments:** never reword, move or merge one. Delete a what, a when, dead code, a
banner, an ownerless TODO, boilerplate, a why that `docs/` or a rule already holds (grep first), or a
why the code contradicts. A long block may be trimmed to a subset of its own lines when those lines
carry the constraint alone. Keep a pointer, a cross-feature doc line that adds information, and
anything you are unsure of. Never touch `// ignore:`, `ignore_for_file`, `dart format off/on`,
`coverage:`, `eslint-`, `@ts-`, `biome-ignore`, `# noqa`, `# type:`, a shebang, or a comment that is
the only body of `{}` (an empty-catch lint).

Prove every cull with `tools/comment-guard/` (Dart, TS/JS, Kotlin, SQL, YAML/TOML/Python):
`inventory.mjs --snapshot [paths]` (baseline = the working tree, not HEAD) → `decisions.jsonl`
(`keep` | `delete` | `trim` with `keep: [lines]`) → `apply.mjs` → `verify.mjs`. `CG_SCOPE` names the
out folder, `CG_ROOT` points it at another repo. The non-comment token stream must match the
baseline; a RED file is re-applied from a corrected decision, never hand-patched.
